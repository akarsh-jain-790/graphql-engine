{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE TemplateHaskell #-}

module Hasura.GraphQL.Schema.BoolExp
  ( AggregationPredicatesSchema (..),
    boolExp,
    mkBoolOperator,
    equalityOperators,
    comparisonOperators,
  )
where

import Data.Has (getter)
import Data.Text.Casing (GQLNameIdentifier)
import Data.Text.Casing qualified as C
import Data.Text.Extended
import Hasura.GraphQL.Parser.Class
import Hasura.GraphQL.Schema.Backend
import Hasura.GraphQL.Schema.Common
import Hasura.GraphQL.Schema.NamingCase
import Hasura.GraphQL.Schema.Options qualified as Options
import Hasura.GraphQL.Schema.Parser
  ( InputFieldsParser,
    Kind (..),
    Parser,
  )
import Hasura.GraphQL.Schema.Parser qualified as P
import Hasura.GraphQL.Schema.Table
import Hasura.GraphQL.Schema.Typename (mkTypename)
import Hasura.Name qualified as Name
import Hasura.Prelude
import Hasura.RQL.IR.BoolExp
import Hasura.RQL.IR.Value
import Hasura.RQL.Types.Backend
import Hasura.RQL.Types.Column
import Hasura.RQL.Types.ComputedField
import Hasura.RQL.Types.Function
import Hasura.RQL.Types.Relationships.Local
import Hasura.RQL.Types.SchemaCache hiding (askTableInfo)
import Hasura.RQL.Types.Source
import Hasura.RQL.Types.SourceCustomization
import Hasura.RQL.Types.Table
import Hasura.SQL.Backend (BackendType)
import Language.GraphQL.Draft.Syntax qualified as G

-- | Backends implement this type class to specify the schema of
-- aggregation predicates.
--
-- The default implementation results in a parser that does not parse anything.
--
-- The scope of this class is local to the function 'boolExp'. In particular,
-- methods in `class BackendSchema` and `type MonadBuildSchema` should *NOT*
-- include this class as a constraint.
class AggregationPredicatesSchema (b :: BackendType) where
  aggregationPredicatesParser ::
    forall r m n.
    MonadBuildSourceSchema r m n =>
    SourceInfo b ->
    TableInfo b ->
    SchemaT r m (Maybe (InputFieldsParser n [AggregationPredicates b (UnpreparedValue b)]))

-- Overlapping instance for backends that do not implement Aggregation Predicates.
instance {-# OVERLAPPABLE #-} (AggregationPredicates b ~ Const Void) => AggregationPredicatesSchema (b :: BackendType) where
  aggregationPredicatesParser ::
    forall r m n.
    (MonadBuildSchemaBase r m n) =>
    SourceInfo b ->
    TableInfo b ->
    SchemaT r m (Maybe (InputFieldsParser n [AggregationPredicates b (UnpreparedValue b)]))
  aggregationPredicatesParser _ _ = return Nothing

-- |
-- > input type_bool_exp {
-- >   _or: [type_bool_exp!]
-- >   _and: [type_bool_exp!]
-- >   _not: type_bool_exp
-- >   column: type_comparison_exp
-- >   ...
-- > }
boolExp ::
  forall b r m n.
  (MonadBuildSchema b r m n, AggregationPredicatesSchema b) =>
  SourceInfo b ->
  TableInfo b ->
  SchemaT r m (Parser 'Input n (AnnBoolExp b (UnpreparedValue b)))
boolExp sourceInfo tableInfo = P.memoizeOn 'boolExp (_siName sourceInfo, tableName) $ do
  tCase <- asks getter
  tableGQLName <- getTableIdentifierName tableInfo
  name <- mkTypename $ applyTypeNameCaseIdentifier tCase $ mkTableBoolExpTypeName tableGQLName
  let description =
        G.Description $
          "Boolean expression to filter rows from the table " <> tableName
            <<> ". All fields are combined with a logical 'AND'."

  fieldInfos <- tableSelectFields sourceInfo tableInfo
  tableFieldParsers <- catMaybes <$> traverse mkField fieldInfos
  -- TODO: This naming is somewhat unsatifactory..
  aggregationPredicatesParser' <- fromMaybe (pure []) <$> aggregationPredicatesParser sourceInfo tableInfo
  recur <- boolExp sourceInfo tableInfo
  -- Bafflingly, ApplicativeDo doesn’t work if we inline this definition (I
  -- think the TH splices throw it off), so we have to define it separately.
  let connectiveFieldParsers =
        [ P.fieldOptional Name.__or Nothing (BoolOr <$> P.list recur),
          P.fieldOptional Name.__and Nothing (BoolAnd <$> P.list recur),
          P.fieldOptional Name.__not Nothing (BoolNot <$> recur)
        ]

  pure $
    BoolAnd <$> P.object name (Just description) do
      tableFields <- map BoolField . catMaybes <$> sequenceA tableFieldParsers
      specialFields <- catMaybes <$> sequenceA connectiveFieldParsers
      aggregationPredicateFields <- map (BoolField . AVAggregationPredicates) <$> aggregationPredicatesParser'
      pure (tableFields ++ specialFields ++ aggregationPredicateFields)
  where
    tableName = tableInfoName tableInfo

    mkField ::
      FieldInfo b ->
      SchemaT r m (Maybe (InputFieldsParser n (Maybe (AnnBoolExpFld b (UnpreparedValue b)))))
    mkField fieldInfo = runMaybeT do
      roleName <- retrieve scRole
      fieldName <- hoistMaybe $ fieldInfoGraphQLName fieldInfo
      P.fieldOptional fieldName Nothing <$> case fieldInfo of
        -- field_name: field_type_comparison_exp
        FIColumn columnInfo ->
          lift $ fmap (AVColumn columnInfo) <$> comparisonExps @b sourceInfo (ciType columnInfo)
        -- field_name: field_type_bool_exp
        FIRelationship relationshipInfo -> do
          remoteTableInfo <- askTableInfo sourceInfo $ riRTable relationshipInfo
          let remoteTableFilter =
                (fmap . fmap) partialSQLExpToUnpreparedValue $
                  maybe annBoolExpTrue spiFilter $
                    tableSelectPermissions roleName remoteTableInfo
          remoteBoolExp <- lift $ boolExp sourceInfo remoteTableInfo
          pure $ fmap (AVRelationship relationshipInfo . andAnnBoolExps remoteTableFilter) remoteBoolExp
        FIComputedField ComputedFieldInfo {..} -> do
          let ComputedFieldFunction {..} = _cfiFunction
          -- For a computed field to qualify in boolean expression it shouldn't have any input arguments
          case toList _cffInputArgs of
            [] -> do
              let functionArgs =
                    flip FunctionArgsExp mempty $
                      fromComputedFieldImplicitArguments @b UVSession _cffComputedFieldImplicitArgs

              fmap (AVComputedField . AnnComputedFieldBoolExp _cfiXComputedFieldInfo _cfiName _cffName functionArgs)
                <$> case computedFieldReturnType @b _cfiReturnType of
                  ReturnsScalar scalarType -> lift $ fmap CFBEScalar <$> comparisonExps @b sourceInfo (ColumnScalar scalarType)
                  ReturnsTable table -> do
                    info <- askTableInfo sourceInfo table
                    lift $ fmap (CFBETable table) <$> boolExp sourceInfo info
                  ReturnsOthers -> hoistMaybe Nothing
            _ -> hoistMaybe Nothing

        -- Using remote relationship fields in boolean expressions is not supported.
        FIRemoteRelationship _ -> empty

{- Note [Nullability in comparison operators]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

In comparisonExps, we hardcode most operators with `Nullability False` when
calling `column`, which might seem a bit sketchy. Shouldn’t the nullability
depend on the nullability of the underlying Postgres column?

No. If we did that, then we would allow boolean expressions like this:

    delete_users(where: {status: {eq: null}})

which in turn would generate a SQL query along the lines of:

    DELETE FROM users WHERE users.status = NULL

but `= NULL` might not do what they expect. For instance, on Postgres, it always
evaluates to False!

Even operators for which `null` is a valid value must be careful in their
implementation. An explicit `null` must always be handled explicitly! If,
instead, an explicit null is ignored:

    foo <- fmap join $ fieldOptional "_foo_level" $ nullable int

then

       delete_users(where: {_foo_level: null})
    => delete_users(where: {})
    => delete_users()

Now we’ve gone and deleted every user in the database. Whoops! Hopefully the
user had backups!

In most cases, as mentioned above, we avoid this problem by making the column
value non-nullable (which is correct, since we never treat a null value as a SQL
NULL), then creating the field using 'fieldOptional'. This creates a parser that
rejects nulls, but won’t be called at all if the field is not specified, which
is permitted by the GraphQL specification. See Note [The value of omitted
fields] in Hasura.GraphQL.Parser.Internal.Parser for more details.

Additionally, it is worth nothing that the `column` parser *does* handle
explicit nulls, by creating a Null column value.

But... the story doesn't end there. Some of our users WANT this peculiar
behaviour. For instance, they want to be able to express the following:

    query($isVerified: Boolean) {
      users(where: {_isVerified: {_eq: $isVerified}}) {
        name
      }
    }

    $isVerified is True  -> return users who are verified
    $isVerified is False -> return users who aren't
    $isVerified is null  -> return all users

In the future, we will likely introduce a separate group of operators that do
implement this particular behaviour explicitly; but for now we have an option that
reverts to the previous behaviour.

To do so, we have to treat explicit nulls as implicit one: this is what the
'nullable' combinator does: it treats an explicit null as if the field has never
been called at all.
-}

-- This is temporary, and should be removed as soon as possible.
mkBoolOperator ::
  (MonadParse n, 'Input P.<: k) =>
  -- | Naming convention for the field
  NamingCase ->
  -- | shall this be collapsed to True when null is given?
  Options.DangerouslyCollapseBooleans ->
  -- | name of this operator
  GQLNameIdentifier ->
  -- | optional description
  Maybe G.Description ->
  -- | parser for the underlying value
  Parser k n a ->
  InputFieldsParser n (Maybe a)
mkBoolOperator tCase Options.DangerouslyCollapseBooleans name desc = fmap join . P.fieldOptional (applyFieldNameCaseIdentifier tCase name) desc . P.nullable
mkBoolOperator tCase Options.Don'tDangerouslyCollapseBooleans name desc = P.fieldOptional (applyFieldNameCaseIdentifier tCase name) desc

equalityOperators ::
  (MonadParse n, 'Input P.<: k) =>
  NamingCase ->
  -- | shall this be collapsed to True when null is given?
  Options.DangerouslyCollapseBooleans ->
  -- | parser for one column value
  Parser k n (UnpreparedValue b) ->
  -- | parser for a list of column values
  Parser k n (UnpreparedValue b) ->
  [InputFieldsParser n (Maybe (OpExpG b (UnpreparedValue b)))]
equalityOperators tCase collapseIfNull valueParser valueListParser =
  [ mkBoolOperator tCase collapseIfNull (C.fromAutogeneratedTuple $$(G.litGQLIdentifier ["_is", "null"])) Nothing $ bool ANISNOTNULL ANISNULL <$> P.boolean,
    mkBoolOperator tCase collapseIfNull (C.fromAutogeneratedName Name.__eq) Nothing $ AEQ True <$> valueParser,
    mkBoolOperator tCase collapseIfNull (C.fromAutogeneratedName Name.__neq) Nothing $ ANE True <$> valueParser,
    mkBoolOperator tCase collapseIfNull (C.fromAutogeneratedName Name.__in) Nothing $ AIN <$> valueListParser,
    mkBoolOperator tCase collapseIfNull (C.fromAutogeneratedName Name.__nin) Nothing $ ANIN <$> valueListParser
  ]

comparisonOperators ::
  (MonadParse n, 'Input P.<: k) =>
  NamingCase ->
  -- | shall this be collapsed to True when null is given?
  Options.DangerouslyCollapseBooleans ->
  -- | parser for one column value
  Parser k n (UnpreparedValue b) ->
  [InputFieldsParser n (Maybe (OpExpG b (UnpreparedValue b)))]
comparisonOperators tCase collapseIfNull valueParser =
  [ mkBoolOperator tCase collapseIfNull (C.fromAutogeneratedName Name.__gt) Nothing $ AGT <$> valueParser,
    mkBoolOperator tCase collapseIfNull (C.fromAutogeneratedName Name.__lt) Nothing $ ALT <$> valueParser,
    mkBoolOperator tCase collapseIfNull (C.fromAutogeneratedName Name.__gte) Nothing $ AGTE <$> valueParser,
    mkBoolOperator tCase collapseIfNull (C.fromAutogeneratedName Name.__lte) Nothing $ ALTE <$> valueParser
  ]
