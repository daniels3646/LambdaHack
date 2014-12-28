-- | Inventory management and party cycling.
-- TODO: document
module Game.LambdaHack.Client.UI.InventoryClient
  ( getGroupItem, getAnyItems, getStoreItem
  , memberCycle, memberBack, pickLeader
  ) where

import Control.Exception.Assert.Sugar
import Control.Monad
import qualified Data.Char as Char
import qualified Data.EnumMap.Strict as EM
import Data.Function
import qualified Data.IntMap.Strict as IM
import Data.List
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text as T
import qualified NLP.Miniutter.English as MU

import Game.LambdaHack.Client.CommonClient
import Game.LambdaHack.Client.ItemSlot
import qualified Game.LambdaHack.Client.Key as K
import Game.LambdaHack.Client.MonadClient
import Game.LambdaHack.Client.State
import Game.LambdaHack.Client.UI.HumanCmd
import Game.LambdaHack.Client.UI.KeyBindings
import Game.LambdaHack.Client.UI.MonadClientUI
import Game.LambdaHack.Client.UI.MsgClient
import Game.LambdaHack.Client.UI.WidgetClient
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Item
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Request
import Game.LambdaHack.Common.State

data ItemDialogState = ISuitable | IAll | INoEnter
  deriving (Show, Eq)

-- | Let a human player choose any item from a given group.
-- Note that this does not guarantee the chosen item belongs to the group,
-- as the player can override the choice.
-- Used e.g., for applying and projecting.
getGroupItem :: MonadClientUI m
             => (ItemFull -> Bool)  -- ^ which items to consider suitable
             -> Text      -- ^ specific prompt for only suitable items
             -> Text      -- ^ generic prompt
             -> [CStore]  -- ^ initial legal containers
             -> [CStore]  -- ^ legal containers after Calm taken into account
             -> m (SlideOrCmd ((ItemId, ItemFull), Container))
getGroupItem psuit prompt promptGeneric cLegalRaw cLegalAfterCalm = do
  soc <- getFull psuit (\_ _ _ -> prompt) (\_ _ _ -> promptGeneric)
                 cLegalRaw cLegalAfterCalm True False ISuitable
  case soc of
    Left sli -> return $ Left sli
    Right ([(iid, itemFull)], c) -> return $ Right ((iid, itemFull), c)
    Right _ -> assert `failure` soc

-- | Let the human player choose any item from a list of items
-- and let him specify the number of items.
-- Used, e.g., for picking up and inventory manipulation.
getAnyItems :: MonadClientUI m
            => MU.Part   -- ^ the verb describing the action
            -> [CStore]  -- ^ initial legal containers
            -> [CStore]  -- ^ legal containers after Calm taken into account
            -> Bool      -- ^ whether to ask, when the only item
                         --   in the starting container is suitable
            -> Bool      -- ^ whether to ask for the number of items
            -> m (SlideOrCmd ([(ItemId, ItemFull)], Container))
getAnyItems verb cLegalRaw cLegalAfterCalm askWhenLone askNumber = do
  let prompt = makePhrase ["What to", verb]
  soc <- getFull (const True) (\_ _ _ -> prompt) (\_ _ _ -> prompt)
                 cLegalRaw cLegalAfterCalm
                 askWhenLone True ISuitable
  case soc of
    Left _ -> return soc
    Right ([(iid, itemFull)], c) -> do
      socK <- pickNumber askNumber $ itemK itemFull
      case socK of
        Left slides -> return $ Left slides
        Right k ->
          return $ Right ([(iid, itemFull{itemK=k})], c)
    Right _ -> return soc

-- | Display all items from a store and let the human player choose any
-- or switch to any other store.
-- Used, e.g., for viewing inventory and item descriptions.
getStoreItem :: MonadClientUI m
             => (Actor -> [ItemFull] -> Container -> Text)
                                 -- ^ how to describe suitable items
             -> Container        -- ^ initial container
             -> Bool             -- ^ whether Enter should be disabled
             -> m (SlideOrCmd ((ItemId, ItemFull), Container))
getStoreItem prompt cInitial noEnter = do
  leader <- getLeaderUI
  let allStores = map (CActor leader) [CEqp, CInv, CSha, CGround]
      dialogState = if noEnter then INoEnter else ISuitable
  soc <- getItem (const True) prompt prompt cInitial (delete cInitial allStores)
                 True False dialogState
  case soc of
    Left sli -> return $ Left sli
    Right ([(iid, itemFull)], c) -> return $ Right ((iid, itemFull), c)
    Right _ -> assert `failure` soc

-- | Let the human player choose a single, preferably suitable,
-- item from a list of items. Don't display stores empty for all actors.
-- Start with a non-empty store.
getFull :: MonadClientUI m
        => (ItemFull -> Bool)  -- ^ which items to consider suitable
        -> (Actor -> [ItemFull] -> Container -> Text)
                            -- ^ specific prompt for only suitable items
        -> (Actor -> [ItemFull] -> Container -> Text)
                            -- ^ generic prompt
        -> [CStore]         -- ^ initial legal containers
        -> [CStore]         -- ^ legal containers with Calm taken into account
        -> Bool             -- ^ whether to ask, when the only item
                            --   in the starting container is suitable
        -> Bool             -- ^ whether to permit multiple items as a result
        -> ItemDialogState  -- ^ the dialog state to start in
        -> m (SlideOrCmd ([(ItemId, ItemFull)], Container))
getFull psuit prompt promptGeneric cLegalRaw cLegalAfterCalm
        askWhenLone permitMulitple initalState = do
  side <- getsClient sside
  leader <- getLeaderUI
  let aidNotEmpty store aid = do
        bag <- getsState $ getCBag (CActor aid store)
        return $! not $ EM.null bag
      partyNotEmpty store = do
        as <- getsState $ fidActorNotProjAssocs side
        bs <- mapM (aidNotEmpty store . fst) as
        return $! or bs
  -- Move the first store that is non-empty for this actor to the front, if any.
  getCStoreBag <- getsState $ \s cstore -> getCBag (CActor leader cstore) s
  let hasThisActor = not . EM.null . getCStoreBag
  case find hasThisActor cLegalAfterCalm of
    Nothing ->
      if isNothing (find hasThisActor cLegalRaw) then do
        let contLegalRaw = map (CActor leader) cLegalRaw
            tLegal = map (MU.Text . ppContainer) contLegalRaw
            ppLegal = makePhrase [MU.WWxW "nor" tLegal]
        failWith $ "no items" <+> ppLegal
      else failSer ItemNotCalm
    Just cThisActor -> do
      -- Don't display stores empty for all actors.
      cLegalNotEmpty <- filterM partyNotEmpty cLegalRaw
      getItem psuit prompt promptGeneric
              (CActor leader cThisActor)
              (map (CActor leader) $ delete cThisActor cLegalNotEmpty)
              askWhenLone permitMulitple initalState

-- | Let the human player choose a single, preferably suitable,
-- item from a list of items.
getItem :: MonadClientUI m
        => (ItemFull -> Bool)  -- ^ which items to consider suitable
        -> (Actor -> [ItemFull] -> Container -> Text)
                            -- ^ specific prompt for only suitable items
        -> (Actor -> [ItemFull] -> Container -> Text)
                            -- ^ generic prompt
        -> Container        -- ^ first legal container
        -> [Container]      -- ^ the rest of legal containers
        -> Bool             -- ^ whether to ask, when the only item
                            --   in the starting container is suitable
        -> Bool             -- ^ whether to permit multiple items as a result
        -> ItemDialogState  -- ^ the dialog state to start in
        -> m (SlideOrCmd ([(ItemId, ItemFull)], Container))
getItem psuit prompt promptGeneric cCur cRest askWhenLone permitMulitple
        initalState = do
  let cLegal = cCur : cRest
  leader <- getLeaderUI
  accessCBag <- getsState $ flip getCBag
  let storeAssocs = EM.assocs . accessCBag
      allAssocs = concatMap storeAssocs cLegal
  mapM_ (\c -> mapM_ (updateItemSlot c (Just leader))
                     (EM.keys $ accessCBag c)) cLegal
  case (cRest, allAssocs) of
    ([], [(iid, k)]) | not askWhenLone -> do
      itemToF <- itemToFullClient
      return $ Right ([(iid, itemToF iid k)], cCur)
    _ ->
      transition psuit prompt promptGeneric cCur cRest
                 permitMulitple initalState

data DefItemKey m = DefItemKey
  { defLabel  :: Text  -- ^ can be undefined if not @defCond@
  , defCond   :: !Bool
  , defAction :: K.KM -> m (SlideOrCmd ([(ItemId, ItemFull)], Container))
  }

transition :: forall m. MonadClientUI m
           => (ItemFull -> Bool)
           -> (Actor -> [ItemFull] -> Container -> Text)
           -> (Actor -> [ItemFull] -> Container -> Text)
           -> Container
           -> [Container]
           -> Bool
           -> ItemDialogState
           -> m (SlideOrCmd ([(ItemId, ItemFull)], Container))
transition psuit prompt promptGeneric cCur cRest permitMulitple
           itemDialogState = do
  let cLegal = cCur : cRest
  (letterSlots, numberSlots, organSlots) <- getsClient sslots
  leader <- getLeaderUI
  body <- getsState $ getActorBody leader
  activeItems <- activeItemsClient leader
  fact <- getsState $ (EM.! bfid body) . sfactionD
  hs <- partyAfterLeader leader
  bag <- getsState $ getCBag cCur
  itemToF <- itemToFullClient
  Binding{brevMap} <- askBinding
  let getSingleResult :: ItemId -> (ItemId, ItemFull)
      getSingleResult iid = (iid, itemToF iid (bag EM.! iid))
      getResult :: ItemId -> ([(ItemId, ItemFull)], Container)
      getResult iid = ([getSingleResult iid], cCur)
      getMultResult :: [ItemId] -> ([(ItemId, ItemFull)], Container)
      getMultResult iids = (map getSingleResult iids, cCur)
      filterP iid kit = psuit $ itemToF iid kit
      bagSuit = EM.filterWithKey filterP bag
      isOrgan = case cCur of
        CActor _ COrgan -> True
        _ -> False
      lSlots = if isOrgan then organSlots else letterSlots
      bagLetterSlots = EM.filter (`EM.member` bag) lSlots
      bagNumberSlots = IM.filter (`EM.member` bag) numberSlots
      suitableLetterSlots = EM.filter (`EM.member` bagSuit) lSlots
      (autoDun, autoLvl) = autoDungeonLevel fact
      normalizeState INoEnter = ISuitable
      normalizeState x = x
      enterSlots = if itemDialogState == IAll
                   then bagLetterSlots
                   else suitableLetterSlots
      keyDefs :: [(K.KM, DefItemKey m)]
      keyDefs = filter (defCond . snd)
        [ (K.toKM K.NoModifier $ K.Char '?', DefItemKey
           { defLabel = "?"
           , defCond = bag /= bagSuit || itemDialogState == INoEnter
           , defAction = \_ -> case normalizeState itemDialogState of
               ISuitable | bag /= bagSuit ->
                 transition psuit prompt promptGeneric cCur cRest
                            permitMulitple IAll
               _ ->
                 transition psuit prompt promptGeneric cCur cRest
                            permitMulitple ISuitable
           })
        , (K.toKM K.NoModifier $ K.Char '/', DefItemKey
           { defLabel = "/"
           , defCond = length cLegal > 1
           , defAction = \_ -> do
               let calmE = calmEnough body activeItems
                   (cCurAfterCalm, cRestAfterCalm) = case cRest ++ [cCur] of
                     c1@(CActor _ CSha) : c2 : rest | not calmE ->
                       (c2, c1 : rest)
                     [CActor _ CSha] | not calmE -> assert `failure` cLegal
                     c1 : rest -> (c1, rest)
                     [] -> assert `failure` cLegal
               transition psuit prompt promptGeneric
                          cCurAfterCalm cRestAfterCalm permitMulitple
                          (normalizeState itemDialogState)
           })
        , (K.toKM K.NoModifier $ K.Char '*', DefItemKey
           { defLabel = "*"
           , defCond = permitMulitple && not (EM.null enterSlots)
           , defAction = \_ -> return $ Right
                               $ getMultResult $ EM.elems enterSlots
           })
        , (K.toKM K.NoModifier $ K.Return, DefItemKey
           { defLabel = case EM.maxViewWithKey enterSlots of
               Nothing -> assert `failure` "no suitable items"
                                 `twith` enterSlots
               Just ((l, _), _) -> "RET(" <> T.singleton (slotChar l) <> ")"
           , defCond = not (EM.null enterSlots
                            || itemDialogState == INoEnter)
           , defAction = \_ -> case EM.maxView enterSlots of
               Nothing -> assert `failure` "no suitable items"
                                 `twith` enterSlots
               Just (iid, _) -> return $ Right $ getResult iid
           })
        , (K.toKM K.NoModifier $ K.Char '0', DefItemKey
           -- TODO: accept any number and pick the item
           { defLabel = "0"
           , defCond = not $ IM.null bagNumberSlots
           , defAction = \_ -> case IM.minView bagNumberSlots of
               Nothing -> assert `failure` "no numbered items"
                                 `twith` bagNumberSlots
               Just (iid, _) -> return $ Right $ getResult iid
           })
        , let km = fromMaybe (K.toKM K.NoModifier K.Tab)
                   $ M.lookup MemberCycle brevMap
          in (km, DefItemKey
           { defLabel = K.showKM km
           , defCond = not (autoLvl
                            || null (filter (\(_, b) ->
                                               blid b == blid body) hs))
           , defAction = \_ -> do
               err <- memberCycle False
               assert (err == mempty `blame` err) skip
               (cCurUpd, cRestUpd) <- legalWithUpdatedLeader cCur cRest
               transition psuit prompt promptGeneric
                          cCurUpd cRestUpd permitMulitple itemDialogState
           })
        , let km = fromMaybe (K.toKM K.NoModifier K.Tab)
                   $ M.lookup MemberBack brevMap
          in (km, DefItemKey
           { defLabel = K.showKM km
           , defCond = not (autoDun || null hs)
           , defAction = \_ -> do
               err <- memberBack False
               assert (err == mempty `blame` err) skip
               (cCurUpd, cRestUpd) <- legalWithUpdatedLeader cCur cRest
               transition psuit prompt promptGeneric
                          cCurUpd cRestUpd permitMulitple itemDialogState
           })
        ]
      lettersDef :: DefItemKey m
      lettersDef = DefItemKey
        { defLabel = slotRange $ EM.keys labelLetterSlots
        , defCond = True
        , defAction = \K.KM{key} -> case key of
            K.Char l -> case EM.lookup (SlotChar l) bagLetterSlots of
              Nothing -> assert `failure` "unexpected slot"
                                `twith` (l, bagLetterSlots)
              Just iid -> return $ Right $ getResult iid
            _ -> assert `failure` "unexpected key:" `twith` K.showKey key
        }
      ppCur = ppContainer cCur
      (labelLetterSlots, bagFiltered, promptChosen) =
        case itemDialogState of
          ISuitable -> (suitableLetterSlots,
                        bagSuit,
                        prompt body activeItems cCur <+> ppCur <> ":")
          IAll      -> (bagLetterSlots,
                        bag,
                        promptGeneric body activeItems cCur <+> ppCur <> ":")
          INoEnter  -> (suitableLetterSlots,
                        EM.empty,
                        prompt body activeItems cCur <+> ppCur <> ":")
  io <- itemOverlay cCur (blid body) bagFiltered
  runDefItemKey keyDefs lettersDef io bagLetterSlots promptChosen

legalWithUpdatedLeader :: MonadClientUI m
                       => Container
                       -> [Container]
                       -> m (Container, [Container])
legalWithUpdatedLeader cCur cRest = do
  leader <- getLeaderUI
  let newC c = case c of
        CActor _oldLeader cstore -> CActor leader cstore
        _ -> c
      newLegal = map newC $ cCur : cRest
  accessCBag <- getsState $ flip getCBag
  mapM_ (\c -> mapM_ (updateItemSlot c (Just leader))
                     (EM.keys $ accessCBag c)) newLegal
  b <- getsState $ getActorBody leader
  activeItems <- activeItemsClient leader
  let calmE = calmEnough b activeItems
      legalAfterCalm = case newLegal of
        c1@(CActor _ CSha) : c2 : rest | not calmE -> (c2, c1 : rest)
        [CActor _ CSha] | not calmE -> (CActor leader CGround, newLegal)
        c1 : rest -> (c1, rest)
        [] -> assert `failure` (cCur, cRest)
  return legalAfterCalm

runDefItemKey :: MonadClientUI m
              => [(K.KM, DefItemKey m)]
              -> DefItemKey m
              -> Overlay
              -> EM.EnumMap SlotChar ItemId
              -> Text
              -> m (SlideOrCmd ([(ItemId, ItemFull)], Container))
runDefItemKey keyDefs lettersDef io labelLetterSlots prompt = do
  let itemKeys =
        let slotKeys = map (K.Char . slotChar) (EM.keys labelLetterSlots)
            defKeys = map fst keyDefs
        in zipWith K.toKM (repeat K.NoModifier) slotKeys ++ defKeys
      choice = let letterRange = defLabel lettersDef
                   letterLabel | T.null letterRange = []
                               | otherwise = [letterRange]
                   keyLabels = letterLabel ++ map (defLabel . snd) keyDefs
               in "[" <> T.intercalate ", " keyLabels
  akm <- displayChoiceUI (prompt <+> choice) io itemKeys
  case akm of
    Left slides -> failSlides slides
    Right km -> do
      case lookup km keyDefs of
        Just keyDef -> defAction keyDef km
        Nothing -> defAction lettersDef km

pickNumber :: MonadClientUI m => Bool -> Int -> m (SlideOrCmd Int)
pickNumber askNumber kAll = do
  let kDefault = kAll
  if askNumber && kAll > 1 then do
    let tDefault = tshow kDefault
        kbound = min 9 kAll
        kprompt = "Choose number [1-" <> tshow kbound
                  <> ", RET(" <> tDefault <> ")"
        kkeys = zipWith K.toKM (repeat K.NoModifier)
                $ map (K.Char . Char.intToDigit) [1..kbound]
                  ++ [K.Return]
    kkm <- displayChoiceUI kprompt emptyOverlay kkeys
    case kkm of
      Left slides -> failSlides slides
      Right K.KM{key} ->
        case key of
          K.Char l -> return $ Right $ Char.digitToInt l
          K.Return -> return $ Right kDefault
          _ -> assert `failure` "unexpected key:" `twith` kkm
  else return $ Right kAll

-- | Switches current member to the next on the level, if any, wrapping.
memberCycle :: MonadClientUI m => Bool -> m Slideshow
memberCycle verbose = do
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  leader <- getLeaderUI
  body <- getsState $ getActorBody leader
  hs <- partyAfterLeader leader
  let autoLvl = snd $ autoDungeonLevel fact
  case filter (\(_, b) -> blid b == blid body) hs of
    _ | autoLvl -> failMsg $ showReqFailure NoChangeLvlLeader
    [] -> failMsg "cannot pick any other member on this level"
    (np, b) : _ -> do
      success <- pickLeader verbose np
      assert (success `blame` "same leader" `twith` (leader, np, b)) skip
      return mempty

-- | Switches current member to the previous in the whole dungeon, wrapping.
memberBack :: MonadClientUI m => Bool -> m Slideshow
memberBack verbose = do
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  leader <- getLeaderUI
  hs <- partyAfterLeader leader
  let autoDun = fst $ autoDungeonLevel fact
  case reverse hs of
    _ | autoDun -> failMsg $ showReqFailure NoChangeDunLeader
    [] -> failMsg "no other member in the party"
    (np, b) : _ -> do
      success <- pickLeader verbose np
      assert (success `blame` "same leader" `twith` (leader, np, b)) skip
      return mempty

partyAfterLeader :: MonadStateRead m => ActorId -> m [(ActorId, Actor)]
partyAfterLeader leader = do
  faction <- getsState $ bfid . getActorBody leader
  allA <- getsState $ EM.assocs . sactorD
  s <- getState
  let hs9 = mapMaybe (tryFindHeroK s faction) [0..9]
      factionA = filter (\(_, body) ->
        not (bproj body) && bfid body == faction) allA
      hs = hs9 ++ deleteFirstsBy ((==) `on` fst) factionA hs9
      i = fromMaybe (-1) $ findIndex ((== leader) . fst) hs
      (lt, gt) = (take i hs, drop (i + 1) hs)
  return $! gt ++ lt

-- | Select a faction leader. False, if nothing to do.
pickLeader :: MonadClientUI m => Bool -> ActorId -> m Bool
pickLeader verbose aid = do
  leader <- getLeaderUI
  stgtMode <- getsClient stgtMode
  if leader == aid
    then return False -- already picked
    else do
      pbody <- getsState $ getActorBody aid
      assert (not (bproj pbody) `blame` "projectile chosen as the leader"
                                `twith` (aid, pbody)) skip
      -- Even if it's already the leader, give his proper name, not 'you'.
      let subject = partActor pbody
      when verbose $ msgAdd $ makeSentence [subject, "picked as a leader"]
      -- Update client state.
      s <- getState
      modifyClient $ updateLeader aid s
      -- Move the cursor, if active, to the new level.
      case stgtMode of
        Nothing -> return ()
        Just _ ->
          modifyClient $ \cli -> cli {stgtMode = Just $ TgtMode $ blid pbody}
      -- Inform about items, etc.
      lookMsg <- lookAt False "" True (bpos pbody) aid ""
      when verbose $ msgAdd lookMsg
      return True
