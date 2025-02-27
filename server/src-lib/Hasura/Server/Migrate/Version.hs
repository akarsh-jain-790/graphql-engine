module Hasura.Server.Migrate.Version
  ( MetadataCatalogVersion (..),
    SourceCatalogVersion (..),
  )
where

import Data.List (isPrefixOf)
import Hasura.Prelude
import Hasura.SQL.Backend (BackendType)
import Language.Haskell.TH.Lift (Lift)

-- | Represents the catalog version. This is stored in the database and then
-- compared with the latest version on startup.
data MetadataCatalogVersion
  = -- | A typical catalog version.
    MetadataCatalogVersion Int
  | -- | Maintained for compatibility with catalog version 0.8.
    MetadataCatalogVersion08
  deriving stock (Eq, Lift)

instance Ord MetadataCatalogVersion where
  compare = compare `on` toFloat
    where
      toFloat :: MetadataCatalogVersion -> Float
      toFloat (MetadataCatalogVersion v) = fromIntegral v
      toFloat MetadataCatalogVersion08 = 0.8

instance Enum MetadataCatalogVersion where
  toEnum = MetadataCatalogVersion
  fromEnum (MetadataCatalogVersion v) = v
  fromEnum MetadataCatalogVersion08 = error "Cannot enumerate unstable catalog versions."

instance Show MetadataCatalogVersion where
  show (MetadataCatalogVersion v) = show v
  show MetadataCatalogVersion08 = "0.8"

instance Read MetadataCatalogVersion where
  readsPrec prec s
    | "0.8" `isPrefixOf` s =
      [(MetadataCatalogVersion08, drop 3 s)]
    | otherwise =
      map (first MetadataCatalogVersion) $ filter ((>= 0) . fst) $ readsPrec @Int prec s

-- | This is the source catalog version, used when deciding whether to (re-)create event triggers.
newtype SourceCatalogVersion (backend :: BackendType) = SourceCatalogVersion Int
  deriving newtype (Eq, Enum, Show, Read)
  deriving stock (Lift)
