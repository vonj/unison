{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE OverloadedStrings   #-}

module Unison.Name
  ( Name(Name)
  , Convert(..)
  , Parse(..)
  , endsWithSegments
  , fromString
  , isPrefixOf
  , joinDot
  , makeAbsolute
  , parent
  , sortNames
  , sortNamed
  , sortByText
  , sortNamed'
  , stripNamePrefix
  , stripPrefixes
  , segments
  , segments'
  , suffixes
  , toString
  , toText
  , toVar
  , unqualified
  , unqualified'
  , unsafeFromText
  , unsafeFromString
  , fromSegment
  , fromVar
  )
where

import           Unison.Prelude
import qualified Unison.NameSegment            as NameSegment
import           Unison.NameSegment             ( NameSegment(NameSegment)
                                                , segments'
                                                )

import           Control.Lens                   ( unsnoc )
import qualified Control.Lens                  as Lens
import qualified Data.Text                     as Text
import qualified Unison.Hashable               as H
import           Unison.Var                     ( Var )
import qualified Unison.Var                    as Var
import qualified Data.RFC5051                  as RFC5051
import           Data.List                      ( sortBy, tails )

newtype Name = Name { toText :: Text }
  deriving (Eq, Ord, Monoid, Semigroup, Generic)

sortNames :: [Name] -> [Name]
sortNames = sortNamed id

sortNamed :: (a -> Name) -> [a] -> [a]
sortNamed by = sortByText (toText . by)

sortByText :: (a -> Text) -> [a] -> [a]
sortByText by as = let
  as' = [ (a, by a) | a <- as ]
  comp (_,s) (_,s2) = RFC5051.compareUnicode s s2
  in fst <$> sortBy comp as'

-- | Like sortNamed, but takes an additional backup comparison function if two
-- names are equal.
sortNamed' :: (a -> Name) -> (a -> a -> Ordering) -> [a] -> [a]
sortNamed' by by2 as = let
  as' = [ (a, toText (by a)) | a <- as ]
  comp (a,s) (a2,s2) = RFC5051.compareUnicode s s2 <> by2 a a2
  in fst <$> sortBy comp as'

unsafeFromText :: Text -> Name
unsafeFromText t =
  if Text.any (== '#') t then error $ "not a name: " <> show t else Name t

unsafeFromString :: String -> Name
unsafeFromString = unsafeFromText . Text.pack

toVar :: Var v => Name -> v
toVar (Name t) = Var.named t

fromVar :: Var v => v -> Name
fromVar = unsafeFromText . Var.name

toString :: Name -> String
toString = Text.unpack . toText

isPrefixOf :: Name -> Name -> Bool
a `isPrefixOf` b = toText a `Text.isPrefixOf` toText b

-- foo.bar.baz `endsWithSegments` bar.baz == True
-- foo.bar.baz `endsWithSegments` baz == True
-- foo.bar.baz `endsWithSegments` az == False (not a full segment)
-- foo.bar.baz `endsWithSegments` zonk == False (doesn't match any segment)
-- foo.bar.baz `endsWithSegments` foo == False (matches a segment, but not at the end)
endsWithSegments :: Name -> Name -> Bool
endsWithSegments n ending = any (== ending) (suffixes n)

-- stripTextPrefix a.b. a.b.c = Just c
-- stripTextPrefix a.b  a.b.c = Just .c;  you probably don't want to do this
-- stripTextPrefix x.y. a.b.c = Nothing
-- stripTextPrefix "" a.b.c = undefined
_stripTextPrefix :: Text -> Name -> Maybe Name
_stripTextPrefix prefix name =
  Name <$> Text.stripPrefix prefix (toText name)

-- stripNamePrefix a.b  a.b.c = Just c
-- stripNamePrefix a.b. a.b.c = undefined, "a.b." isn't a valid name IMO
-- stripNamePrefix x.y  a.b.c = Nothing, x.y isn't a prefix of a.b.c
-- stripNamePrefix "" a.b.c = undefined, "" isn't a valid name IMO
-- stripNamePrefix . .Nat = Just Nat
stripNamePrefix :: Name -> Name -> Maybe Name
stripNamePrefix prefix name =
  Name <$> Text.stripPrefix (toText prefix <> mid) (toText name)
  where
  mid = if toText prefix == "." then "" else "."

-- a.b.c.d -> d
stripPrefixes :: Name -> Name
stripPrefixes = maybe "" fromSegment . lastMay . segments

joinDot :: Name -> Name -> Name
joinDot prefix suffix =
  if toText prefix == "." then Name (toText prefix <> toText suffix)
  else Name (toText prefix <> "." <> toText suffix)

unqualified :: Name -> Name
unqualified = unsafeFromText . unqualified' . toText

-- parent . -> Nothing
-- parent + -> Nothing
-- parent foo -> Nothing
-- parent foo.bar -> foo
-- parent foo.bar.+ -> foo.bar
parent :: Name -> Maybe Name
parent n = case unsnoc (NameSegment.toText <$> segments n) of
  Nothing        -> Nothing
  Just ([]  , _) -> Nothing
  Just (init, _) -> Just $ Name (Text.intercalate "." init)

-- suffixes "" -> []
-- suffixes bar -> [bar]
-- suffixes foo.bar -> [foo.bar, bar]
-- suffixes foo.bar.baz -> [foo.bar.baz, bar.baz, baz]
-- suffixes ".base.." -> [base.., .]
suffixes :: Name -> [Name]
suffixes (Name "") = []
suffixes (Name n ) = fmap up . filter (not . null) . tails $ segments' n
  where up ns = Name (Text.intercalate "." ns)

unqualified' :: Text -> Text
unqualified' = fromMaybe "" . lastMay . segments'

makeAbsolute :: Name -> Name
makeAbsolute n | toText n == "."                = Name ".."
               | Text.isPrefixOf "." (toText n) = n
               | otherwise                      = Name ("." <> toText n)

instance Show Name where
  show = toString

instance IsString Name where
  fromString = unsafeFromText . Text.pack

instance H.Hashable Name where
  tokens s = [H.Text (toText s)]

fromSegment :: NameSegment -> Name
fromSegment = unsafeFromText . NameSegment.toText

-- Smarter segmentation than `text.splitOn "."`
-- e.g. split `base..` into `[base,.]`
segments :: Name -> [NameSegment]
segments (Name n) = NameSegment <$> segments' n

class Convert a b where
  convert :: a -> b

class Parse a b where
  parse :: a -> Maybe b

instance Convert Name Text where convert = toText
instance Convert Name [NameSegment] where convert = segments
instance Convert NameSegment Name where convert = fromSegment

instance Parse Text NameSegment where
  parse txt = case NameSegment.segments' txt of
    [n] -> Just (NameSegment.NameSegment n)
    _ -> Nothing

instance (Parse a a2, Parse b b2) => Parse (a,b) (a2,b2) where
  parse (a,b) = (,) <$> parse a <*> parse b

instance Lens.Snoc Name Name NameSegment NameSegment where
  _Snoc = Lens.prism snoc unsnoc
   where
    snoc :: (Name, NameSegment) -> Name
    snoc (n, s) = joinDot n (fromSegment s)
    unsnoc :: Name -> Either Name (Name, NameSegment)
    unsnoc n@(segments -> ns) = case Lens.unsnoc (NameSegment.toText <$> ns) of
      Nothing      -> Left n
      Just ([], _) -> Left n
      Just (init, last) ->
        Right (Name (Text.intercalate "." init), NameSegment last)
