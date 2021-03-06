{-# LANGUAGE DeriveGeneric #-}
-- | The type of kinds of weapons, treasure, organs, blasts, etc.
module Game.LambdaHack.Content.ItemKind
  ( ItemKind(..), makeData
  , Effect(..), DetectKind(..), TimerDice, ThrowMod(..), Feature(..)
  , ItemSpeedup, emptyItemSpeedup, getKindMean, speedupItem
  , boostItemKindList, forApplyEffect, onlyMinorEffects
  , filterRecharging, stripRecharging, stripOnSmash
  , strengthOnSmash, getDropOrgans, getToThrow, getHideAs, getEqpSlot
  , isEffEscape, isEffAscend, isEffEscapeOrAscend
  , isMelee, isTmpCondition, isBlast, isHumanTrinket
  , goesIntoEqp, goesIntoInv, goesIntoSha
  , itemTrajectory, totalRange, damageUsefulness
  , tmpNoLonger, tmpLess, toVelocity, toLinger
  , timerNone, isTimerNone, foldTimer
  , toOrganBad, toOrganGood, toOrganNoTimer
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , meanAspect, boostItemKind, majorEffect
  , validateSingle, validateAll, validateDups, validateDamage
  , hardwiredItemGroups
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import           Control.DeepSeq
import           Data.Binary
import qualified Data.Text as T
import qualified Data.Vector as V
import           GHC.Generics (Generic)
import qualified NLP.Miniutter.English as MU
import qualified System.Random as R

import           Game.LambdaHack.Common.ContentData
import qualified Game.LambdaHack.Common.Dice as Dice
import           Game.LambdaHack.Common.Flavour
import qualified Game.LambdaHack.Common.ItemAspect as IA
import           Game.LambdaHack.Common.Misc
import           Game.LambdaHack.Common.Point
import           Game.LambdaHack.Common.Time
import           Game.LambdaHack.Common.Vector

-- | Item properties that are fixed for a given kind of items.
-- Note that this type is mutually recursive with 'Effect' and `Feature`.
data ItemKind = ItemKind
  { isymbol  :: Char                -- ^ map symbol
  , iname    :: Text                -- ^ generic name; is pluralized if needed
  , ifreq    :: Freqs ItemKind      -- ^ frequency within groups
  , iflavour :: [Flavour]           -- ^ possible flavours
  , icount   :: Dice.Dice           -- ^ created in that quantity
  , irarity  :: Rarity              -- ^ rarity on given depths
  , iverbHit :: MU.Part             -- ^ the verb for hitting
  , iweight  :: Int                 -- ^ weight in grams
  , idamage  :: Dice.Dice           -- ^ basic impact damage
  , iaspects :: [IA.Aspect]         -- ^ affect the actor continuously
  , ieffects :: [Effect]            -- ^ cause the effects when triggered
  , ifeature :: [Feature]           -- ^ properties of the item
  , idesc    :: Text                -- ^ description
  , ikit     :: [(GroupName ItemKind, CStore)]
                                    -- ^ accompanying organs and equipment
  }
  deriving (Show, Generic)  -- No Eq and Ord to make extending logically sound

-- | Effects of items. Can be invoked by the item wielder to affect
-- another actor or the wielder himself. Many occurences in the same item
-- are possible.
data Effect =
    Burn Dice.Dice     -- ^ burn with this damage
  | Explode (GroupName ItemKind)
                       -- ^ explode producing this group of blasts
  | RefillHP Int       -- ^ modify HP of the actor by this amount
  | RefillCalm Int     -- ^ modify Calm of the actor by this amount
  | Dominate           -- ^ change actor's allegiance
  | Impress            -- ^ make actor susceptible to domination
  | Summon (GroupName ItemKind) Dice.Dice
      -- ^ summon the given number of actors of this group
  | Ascend Bool           -- ^ ascend to another level of the dungeon
  | Escape                -- ^ escape from the dungeon
  | Paralyze Dice.Dice    -- ^ paralyze for this many game clips
  | InsertMove Dice.Dice  -- ^ give free time to actor of this many actor turns
  | Teleport Dice.Dice    -- ^ teleport actor across rougly this distance
  | CreateItem CStore (GroupName ItemKind) TimerDice
      -- ^ create an item of the group and insert into the store with the given
      --   random timer
  | DropItem Int Int CStore (GroupName ItemKind)
      -- ^ make the actor drop items of the given group from the given store;
      --   the first integer says how many item kinds to drop, the second,
      --   how many copies of each kind to drop; for non-organs, beware of
      --   not dropping all, or cluttering store with rubbish becomes beneficial
  | PolyItem
      -- ^ find a suitable (i.e., numerous enough) item, starting from
      --   the floor, and polymorph it randomly
  | Identify
      -- ^ find a suitable (i.e., not identified) item, starting from
      --   the floor, and identify it
  | Detect DetectKind Int -- ^ detect something on the map in the given radius
  | SendFlying ThrowMod   -- ^ send an actor flying (push or pull, depending)
  | PushActor ThrowMod    -- ^ push an actor
  | PullActor ThrowMod    -- ^ pull an actor
  | DropBestWeapon        -- ^ make the actor drop its best weapon
  | ActivateInv Char
      -- ^ activate all items with this symbol in inventory; space character
      --   means all symbols
  | ApplyPerfume          -- ^ remove all smell on the level
  | OneOf [Effect]        -- ^ trigger one of the effects with equal probability
  | OnSmash Effect
      -- ^ trigger the effect when item smashed (not when applied nor meleed)
  | Recharging Effect     -- ^ this effect inactive until timeout passes
  | Composite [Effect]    -- ^ only fire next effect if previous fully activated
  | Temporary Text
      -- ^ the item is temporary, vanishes at even void Periodic activation,
      --   unless Durable and not Fragile, and shows message with
      --   this verb at last copy activation or at each activation
      --   unless Durable and Fragile
  deriving (Show, Eq, Generic)

data DetectKind =
    DetectAll
  | DetectActor
  | DetectItem
  | DetectExit
  | DetectHidden
  | DetectEmbed
  deriving (Show, Eq, Generic)

-- | Specification of how to randomly roll a timer at item creation
-- to obtain a fixed timer for the item's lifetime.
data TimerDice =
    TimerNone
  | TimerGameTurn Dice.Dice
  | TimerActorTurn Dice.Dice
  deriving (Eq, Generic)

instance Show TimerDice where
  show TimerNone = "0"
  show (TimerGameTurn nDm) =
    show nDm ++ " " ++ if nDm == 1 then "turn" else "turns"
  show (TimerActorTurn nDm) =
    show nDm ++ " " ++ if nDm == 1 then "move" else "moves"

-- | Parameters modifying a throw of a projectile or flight of pushed actor.
-- Not additive and don't start at 0.
data ThrowMod = ThrowMod
  { throwVelocity :: Int  -- ^ fly with this percentage of base throw speed
  , throwLinger   :: Int  -- ^ fly for this percentage of 2 turns
  }
  deriving (Show, Eq, Ord, Generic)

-- | Features of item. Affect only the item in question,
-- not the actor carrying it, and so not additive in any sense.
data Feature =
    ELabel Text        -- ^ extra label of the item; it's not pluralized
  | Fragile            -- ^ drop and break at target tile, even if no hit
  | Lobable            -- ^ drop at target tile, even if no hit
  | Durable            -- ^ don't break even when hitting or applying
  | ToThrow ThrowMod   -- ^ parameters modifying a throw
  | HideAs (GroupName ItemKind)
                       -- ^ until identified, presents as this unique kind
  | Equipable          -- ^ AI and UI flag: consider equipping (independent of
                       --   'EqpSlot', e.g., in case of mixed blessings)
  | Meleeable          -- ^ AI and UI flag: consider meleeing with
  | Precious           -- ^ AI and UI flag: don't risk identifying by use;
                       --   also, can't throw or apply if not calm enough
  | Tactic Tactic      -- ^ overrides actor's tactic; WIP; move?
  | Blast              -- ^ the item is an explosion blast particle
  | EqpSlot IA.EqpSlot -- ^ AI and UI flag that leaks item intended use
  | Unique             -- ^ at most one copy can ever be generated
  | Periodic           -- ^ in eqp, triggered as often as @Timeout@ permits
  | MinorEffects       -- ^ override: the effects on this item are considered
                       --   minor and so not causing identification on use,
                       --   and so this item will identify on pick-up
  deriving (Show, Eq, Ord, Generic)

-- | Map from an item kind identifier to the mean aspect value for the kind.
--
-- Significant portions of this map are unused and so intentially kept
-- unevaluated.
newtype ItemSpeedup = ItemSpeedup (V.Vector IA.KindMean)
  deriving (Show, Eq, Generic)

instance NFData ItemKind

instance NFData Effect

instance NFData DetectKind

instance NFData TimerDice

instance NFData ThrowMod

instance NFData Feature

instance Binary Effect

instance Binary DetectKind

instance Binary TimerDice

instance Binary ThrowMod

emptyItemSpeedup :: ItemSpeedup
emptyItemSpeedup = ItemSpeedup V.empty

getKindMean :: ContentId ItemKind -> ItemSpeedup -> IA.KindMean
getKindMean kindId (ItemSpeedup is) = is V.! contentIdIndex kindId

speedupItem :: ContentData ItemKind -> ItemSpeedup
speedupItem coitem =
  let f !kind =
        let kmMean = meanAspect kind
            kmConst = not $ IA.aspectsRandom (iaspects kind)
        in IA.KindMean{..}
  in ItemSpeedup $! omapVector coitem f

meanAspect :: ItemKind -> IA.AspectRecord
meanAspect kind = foldl' IA.addMeanAspect IA.emptyAspectRecord (iaspects kind)

boostItemKindList :: R.StdGen -> [ItemKind] -> [ItemKind]
boostItemKindList _ [] = []
boostItemKindList initialGen l =
  let (r, _) = R.randomR (0, length l - 1) initialGen
  in case splitAt r l of
    (pre, i : post) -> pre ++ boostItemKind i : post
    _               -> error $  "" `showFailure` l

boostItemKind :: ItemKind -> ItemKind
boostItemKind i =
  let mainlineLabel (label, _) =
        label `elem` ["common item", "curious item", "treasure"]
  in if any mainlineLabel (ifreq i)
     then i { ifreq = ("common item", 10000) : filter (not . mainlineLabel) (ifreq i)
            , ifeature = delete Unique $ ifeature i
            }
     else i

-- | Whether the effect has a chance of exhibiting any potentially
-- noticeable behaviour, except when the item is destroyed.
-- We assume at least one of @OneOf@ effects must be noticeable.
forApplyEffect :: Effect -> Bool
forApplyEffect eff = case eff of
  OnSmash{} -> False
  Recharging eff2 -> forApplyEffect eff2
  Composite effs -> any forApplyEffect effs
  Temporary{} -> False
  _ -> True

majorEffect :: Effect -> Bool
majorEffect eff = case eff of
  OnSmash{} -> False
  Recharging eff2 -> majorEffect eff2
  Composite (eff1 : _) -> majorEffect eff1  -- the rest may never fire
  _ -> True

onlyMinorEffects :: ItemKind -> Bool
onlyMinorEffects kind =
  MinorEffects `elem` ifeature kind  -- override
  || not (any majorEffect $ ieffects kind)  -- exhibits no major effects

isEffEscape :: Effect -> Bool
isEffEscape Escape{} = True
isEffEscape (OneOf l) = any isEffEscapeOrAscend l
isEffEscape (Recharging eff) = isEffEscapeOrAscend eff
isEffEscape (Composite l) = any isEffEscapeOrAscend l
isEffEscape _ = False

isEffAscend :: Effect -> Bool
isEffAscend Ascend{} = True
isEffAscend (OneOf l) = any isEffEscapeOrAscend l
isEffAscend (Recharging eff) = isEffEscapeOrAscend eff
isEffAscend (Composite l) = any isEffEscapeOrAscend l
isEffAscend _ = False

isEffEscapeOrAscend :: Effect -> Bool
isEffEscapeOrAscend Ascend{} = True
isEffEscapeOrAscend Escape{} = True
isEffEscapeOrAscend (OneOf l) = any isEffEscapeOrAscend l
isEffEscapeOrAscend (Recharging eff) = isEffEscapeOrAscend eff
isEffEscapeOrAscend (Composite l) = any isEffEscapeOrAscend l
isEffEscapeOrAscend _ = False

filterRecharging :: [Effect] -> [Effect]
filterRecharging effs =
  let getRechargingEffect :: Effect -> Maybe Effect
      getRechargingEffect e@Recharging{} = Just e
      getRechargingEffect _ = Nothing
  in mapMaybe getRechargingEffect effs

stripRecharging :: [Effect] -> [Effect]
stripRecharging effs =
  let getRechargingEffect :: Effect -> Maybe Effect
      getRechargingEffect (Recharging e) = Just e
      getRechargingEffect _ = Nothing
  in mapMaybe getRechargingEffect effs

stripOnSmash :: [Effect] -> [Effect]
stripOnSmash effs =
  let getOnSmashEffect :: Effect -> Maybe Effect
      getOnSmashEffect (OnSmash e) = Just e
      getOnSmashEffect _ = Nothing
  in mapMaybe getOnSmashEffect effs

strengthOnSmash :: ItemKind -> [Effect]
strengthOnSmash =
  let f (OnSmash eff) = [eff]
      f _ = []
  in concatMap f . ieffects

getDropOrgans :: ItemKind -> [GroupName ItemKind]
getDropOrgans =
  let f (DropItem _ _ COrgan grp) = [grp]
      f Impress = ["impressed"]
      f (OneOf l) = concatMap f l
      f (Recharging eff) = f eff
      f (Composite l) = concatMap f l
      f _ = []
  in concatMap f . ieffects

getToThrow :: ItemKind -> ThrowMod
getToThrow itemKind =
  let f (ToThrow tmod) = [tmod]
      f _ = []
  in case concatMap f (ifeature itemKind) of
    [] -> ThrowMod 100 100
    x : _ -> x

getHideAs :: ItemKind -> Maybe (GroupName ItemKind)
getHideAs itemKind =
  let f (HideAs grp) = [grp]
      f _ = []
  in case concatMap f (ifeature itemKind) of
    [] -> Nothing
    x : _ -> Just x

getEqpSlot :: ItemKind -> Maybe IA.EqpSlot
getEqpSlot itemKind =
  let f (EqpSlot eqpSlot) = [eqpSlot]
      f _ = []
  in case concatMap f (ifeature itemKind) of
    [] -> Nothing
    x : _ -> Just x

isMelee :: ItemKind -> Bool
isMelee itemKind = Meleeable `elem` ifeature itemKind

isTmpCondition :: ItemKind -> Bool
isTmpCondition itemKind = Fragile `elem` ifeature itemKind
                          && Durable `elem` ifeature itemKind

isBlast :: ItemKind -> Bool
isBlast itemKind = Blast `elem` ifeature itemKind

isHumanTrinket :: ItemKind -> Bool
isHumanTrinket itemKind =
  Precious `elem` ifeature itemKind  -- risk from treasure hunters
  && Equipable `notElem` ifeature itemKind  -- can't wear

goesIntoEqp :: ItemKind -> Bool
goesIntoEqp itemKind = Equipable `elem` ifeature itemKind
                       || Meleeable `elem` ifeature itemKind

goesIntoInv :: ItemKind -> Bool
goesIntoInv itemKind = Precious `notElem` ifeature itemKind
                       && not (goesIntoEqp itemKind)

goesIntoSha :: ItemKind -> Bool
goesIntoSha itemKind = Precious `elem` ifeature itemKind
                       && not (goesIntoEqp itemKind)

itemTrajectory :: ItemKind -> [Point] -> ([Vector], (Speed, Int))
itemTrajectory itemKind path =
  let ThrowMod{..} = getToThrow itemKind
  in computeTrajectory (iweight itemKind) throwVelocity throwLinger path

totalRange :: ItemKind -> Int
totalRange itemKind = snd $ snd $ itemTrajectory itemKind []

damageUsefulness :: ItemKind -> Double
damageUsefulness itemKind =
  let v = min 1000 (10 * Dice.meanDice (idamage itemKind))
  in assert (v >= 0) v

tmpNoLonger :: Text -> Effect
tmpNoLonger name = Temporary $ "be no longer" <+> name

tmpLess :: Text -> Effect
tmpLess name = Temporary $ "become less" <+> name

toVelocity :: Int -> Feature
toVelocity n = ToThrow $ ThrowMod n 100

toLinger :: Int -> Feature
toLinger n = ToThrow $ ThrowMod 100 n

timerNone :: TimerDice
timerNone = TimerNone

isTimerNone :: TimerDice -> Bool
isTimerNone tim = tim == TimerNone

foldTimer :: a -> (Dice.Dice -> a) -> (Dice.Dice -> a) -> TimerDice -> a
foldTimer a fgame factor tim = case tim of
  TimerNone -> a
  TimerGameTurn nDm -> fgame nDm
  TimerActorTurn nDm -> factor nDm

toOrganBad :: GroupName ItemKind -> Dice.Dice -> Effect
toOrganBad grp nDm =
  assert (Dice.minDice nDm > 0
          `blame` "dice at organ creation should always roll above zero"
          `swith` (grp, nDm))
  $ CreateItem COrgan grp (TimerGameTurn nDm)

toOrganGood :: GroupName ItemKind -> Dice.Dice -> Effect
toOrganGood grp nDm =
  assert (Dice.minDice nDm > 0
          `blame` "dice at organ creation should always roll above zero"
          `swith` (grp, nDm))
  $ CreateItem COrgan grp (TimerActorTurn nDm)

toOrganNoTimer :: GroupName ItemKind -> Effect
toOrganNoTimer grp = CreateItem COrgan grp TimerNone

-- | Catch invalid item kind definitions.
validateSingle :: ItemKind -> [Text]
validateSingle ik@ItemKind{..} =
  [ "iname longer than 23" | T.length iname > 23 ]
  ++ [ "icount < 0" | Dice.minDice icount < 0 ]
  ++ validateRarity irarity
  ++ validateDamage idamage
  -- Reject duplicate Timeout, because it's not additive.
  ++ (let timeoutAspect :: IA.Aspect -> Bool
          timeoutAspect IA.Timeout{} = True
          timeoutAspect _ = False
          ts = filter timeoutAspect iaspects
      in ["more than one Timeout specification" | length ts > 1])
  ++ (let f :: Feature -> Bool
          f EqpSlot{} = True
          f _ = False
          ts = filter f ifeature
      in [ "EqpSlot specified but not Equipable nor Meleeable"
         | length ts > 0 && Equipable `notElem` ifeature
                         && Meleeable `notElem` ifeature ])
  ++ ["Redundant Equipable or Meleeable" | Equipable `elem` ifeature
                                           && Meleeable `elem` ifeature]
  ++ (let f :: Effect -> Bool
          f OnSmash{} = True
          f _ = False
      in validateNotNested ieffects "OnSmash" f)  -- duplicates permitted
  ++ (let f :: Effect -> Bool
          f Recharging{} = True
          f _ = False
      in validateNotNested ieffects "Recharging" f)  -- duplicates permitted
  ++ (let f :: Effect -> Bool
          f Temporary{} = True
          f _ = False
      in validateOnlyOne ieffects "Temporary" f)  -- may be duplicated if nested
  ++ (let f :: Feature -> Bool
          f ELabel{} = True
          f _ = False
          ts = filter f ifeature
      in ["more than one ELabel specification" | length ts > 1])
  ++ (let f :: Feature -> Bool
          f ToThrow{} = True
          f _ = False
          ts = filter f ifeature
      in ["more than one ToThrow specification" | length ts > 1])
  ++ (let f :: Feature -> Bool
          f HideAs{} = True
          f _ = False
          ts = filter f ifeature
      in ["more than one HideAs specification" | length ts > 1])
  ++ (let f :: Feature -> Bool
          f Tactic{} = True
          f _ = False
          ts = filter f ifeature
      in ["more than one Tactic specification" | length ts > 1])
  ++ concatMap (validateDups ik)
       [ Fragile, Lobable, Durable, Equipable, Meleeable, Precious, Blast
       , Unique, Periodic]

-- We only check there are no duplicates at top level. If it may be nested,
-- it may presumably be duplicated inside the nesting as well.
validateOnlyOne :: [Effect] -> Text -> (Effect -> Bool) -> [Text]
validateOnlyOne effs t f =
  let  ts = filter f effs
  in ["more than one" <+> t <+> "specification" | length ts > 1]

-- We check it's not nested one nor more levels.
validateNotNested :: [Effect] -> Text -> (Effect -> Bool) -> [Text]
validateNotNested effs t f =
  let g (OneOf l) = any f l || any g l
      g (OnSmash effect) = f effect || g effect
      g (Recharging effect) = f effect || g effect
      g (Composite l) = any f l || any g l
      g _ = False
      ts = filter g effs
  in [ "effect" <+> t <+> "should be specified at top level, not nested"
     | length ts > 0 ]

validateDups :: ItemKind -> Feature -> [Text]
validateDups ItemKind{..} feat =
  let ts = filter (== feat) ifeature
  in ["more than one" <+> tshow feat <+> "specification" | length ts > 1]

validateDamage :: Dice.Dice -> [Text]
validateDamage dice = [ "potentially negative dice:" <+> tshow dice
                      | Dice.minDice dice < 0]

-- | Validate all item kinds.
validateAll :: [ItemKind] -> ContentData ItemKind -> [Text]
validateAll content coitem =
  let missingKitGroups = [ cgroup
                      | k <- content
                      , (cgroup, _) <- ikit k
                      , not $ omemberGroup coitem cgroup ]
      f :: Feature -> Bool
      f HideAs{} = True
      f _ = False
      wrongHideAsGroups =
        [ cgroup
        | k <- content
        , let (cgroup, notSingleton) = case find f (ifeature k) of
                Just (HideAs grp) | not $ oisSingletonGroup coitem grp ->
                  (grp, True)
                _ -> (undefined, False)
        , notSingleton
        ]
      g :: Effect -> Maybe (GroupName ItemKind)
      g (Explode grp) = Just grp
      g (Summon grp _) = Just grp
      g (CreateItem _ grp _) = Just grp
      g (DropItem _ _ _ grp) = Just grp
      g _ = Nothing
      missingEffectGroups =
        [ (iname k, absGroups)
        | k <- content
        , let grps = mapMaybe g $ ieffects k
              absGroups = filter (not . omemberGroup coitem) grps
        , not $ null absGroups
        ]
      missingHardwiredGroups =
        filter (not . omemberGroup coitem) hardwiredItemGroups
  in [ "no ikit groups in content:" <+> tshow missingKitGroups
     | not $ null missingKitGroups ]
     ++ [ "HideAs groups not singletons:" <+> tshow wrongHideAsGroups
        | not $ null wrongHideAsGroups ]
     ++ [ "mentioned groups not in content:" <+> tshow missingEffectGroups
        | not $ null missingEffectGroups ]
     ++ [ "hardwired groups not in content:" <+> tshow missingHardwiredGroups
        | not $ null missingHardwiredGroups ]

hardwiredItemGroups :: [GroupName ItemKind]
hardwiredItemGroups =
  -- From Preferences.hs:
  ["condition", "common item"]
    -- the others are optional:
    -- "curious item", "treasure", "any scroll", "any vial",
    -- "potion", "explosive", "any jewelry"
  -- Assorted:
  ++ ["bonus HP", "currency", "impressed", "mobile"]

makeData :: [ItemKind] -> ContentData ItemKind
makeData = makeContentData "ItemKind" iname ifreq validateSingle validateAll
