{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns #-}

module U.Codebase.Sqlite.Sync22 where

import qualified Control.Lens as Lens
import Control.Monad (filterM, foldM, join, (<=<))
import Control.Monad.Except (ExceptT, MonadError (throwError))
import Control.Monad.Extra (ifM)
import Control.Monad.RWS (MonadIO, MonadReader (reader))
import Control.Monad.Reader (ReaderT)
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Except (throwE, withExceptT)
import qualified Control.Monad.Writer as Writer
import Data.ByteString (ByteString)
import Data.Bytes.Get (MonadGet, getByteString, getWord8, runGetS)
import Data.Bytes.Put (putWord8, runPutS)
import Data.Foldable (toList, traverse_)
import Data.Functor ((<&>))
import Data.List.Extra (nubOrd)
import Data.Maybe (catMaybes, fromJust, isJust)
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Traversable (for)
import Data.Word (Word64)
import Database.SQLite.Simple (Connection)
import U.Codebase.Sqlite.DbId
import qualified U.Codebase.Sqlite.LocalIds as L
import qualified U.Codebase.Sqlite.ObjectType as OT
import qualified U.Codebase.Sqlite.Queries as Q
import qualified U.Codebase.Sqlite.Serialization as S
import U.Codebase.Sync
import qualified U.Codebase.Sync as Sync
import U.Util.Cache (Cache)
import qualified U.Util.Cache as Cache
import qualified U.Util.Serialization as S

data Entity = O ObjectId | C CausalHashId

data DbTag = SrcDb | DestDb

data DecodeError = ErrTermComponent | ErrDeclComponent

type ErrString = String

data Error
  = DbIntegrity Q.Integrity
  | DecodeError DbTag DecodeError ByteString ErrString
  | -- | hashes corresponding to a single object in source codebase
    --  correspond to multiple objects in destination codebase
    HashObjectCorrespondence ObjectId [HashId] [ObjectId]

data Env = Env
  { srcDB :: Connection,
    destDB :: Connection
  }

-- data Mappings

-- We load an object from the source; it has a bunch of dependencies.
-- Some of these dependencies exist at the defination, some don't.
-- For the ones that do, look up their ids, and update the thingie as you write it
-- For the ones that don't, copy them (then you will know their ids), and update the thingie.
-- If you want, you can try to cache that lookup.

-- sync22 ::
--   ( MonadIO m,
--     MonadError Error m,
--     MonadReader TwoConnections m
--   ) =>
--   Sync m Entity
-- sync22 = Sync roots trySync
--   where
--     roots = runSrc $ fmap (\h -> [C h]) Q.loadNamespaceRoot

trySync ::
  forall m.
  (MonadIO m, MonadError Error m, MonadReader Env m) =>
  Cache m TextId TextId ->
  Cache m HashId HashId ->
  Cache m ObjectId ObjectId ->
  Generation ->
  Entity ->
  m (TrySyncResult Entity)
trySync tCache hCache oCache gc = \case
  -- for causals, we need to get the value_hash_id of the thingo
  -- - maybe enqueue their parents
  -- - enqueue the self_ and value_ hashes
  -- - enqueue the namespace object, if present
  C chId -> do
    chId' <- syncCausalHash chId
    -- we're going to assume that if the dest has this in its
    -- causal table, then it's safe to short-circuit
    ifM
      (runDest $ Q.isCausalHash $ unCausalHashId chId')
      (pure Sync.PreviouslyDone)
      ( do
          bhId <- runSrc $ Q.loadCausalValueHashId chId
          bhId' <- syncBranchHashId bhId

          mayBoId <-
            runSrc . Q.maybeObjectIdForAnyHashId $
              unBranchHashId bhId
          mayBoId' <- join <$> traverse (isSyncedObject) mayBoId

          findMissingParents chId >>= \case
            [] ->
              -- if branch object is present at src and dest,
              -- or absent from both src and dest
              -- then we are done
              if isJust mayBoId == isJust mayBoId'
                then do
                  runDest $ Q.saveCausal chId' bhId'
                  pure Sync.Done
                else -- else it's present at src but not at dest.,
                -- so request it be copied, and revisit later
                  pure $ Missing [O $ fromJust mayBoId]
            missingParents ->
              -- if branch object is present at src and dest,
              -- or absent from both src and dest
              -- but there are parents missing,
              -- then request the parents be copied, and revisit later
              if isJust mayBoId == isJust mayBoId'
                then pure $ Missing missingParents
                else -- otherwise request the branch and the parents be copied
                  pure $ Missing $ (O $ fromJust mayBoId) : missingParents
      )
  -- objects are the hairiest. obviously, if they
  -- exist, we're done; otherwise we do some fancy stuff
  O oId ->
    isSyncedObject oId >>= \case
      Just {} -> pure Sync.PreviouslyDone
      Nothing -> do
        (hId, objType, bytes) <- runSrc $ Q.loadObjectWithHashIdAndTypeById oId
        hId' <- syncHashLiteral hId
        result <- case objType of
          OT.TermComponent -> do
            -- (fmt, termComponent) <-
            --   either (throwError . DecodeError SrcDb ErrTermComponent bytes) pure -- 🤪
            --     . flip runGetS bytes
            --     $ (,) <$> getWord8 <*> S.decomposeTermComponent
            (fmt, unzip3 -> (localIds, termBytes, typeBytes)) <-
              case flip runGetS bytes do
                tag <- getWord8
                component <- S.decomposeTermComponent
                pure (tag, component) of
                Right x -> pure x
                Left s -> throwError $ DecodeError SrcDb ErrTermComponent bytes s
            -- termComponent' <-
            -- S.decomposeTermComponent >>= traverse . Lens.mapMOf Lens._1 do
            foldM foldLocalIds (Right mempty) localIds >>= \case
              Left missingDeps -> pure $ Left missingDeps
              Right (toList -> localIds') -> do
                let bytes' =
                      runPutS $
                        putWord8 fmt
                          >> S.recomposeTermComponent (zip3 localIds' termBytes typeBytes)
                oId' <- runDest $ Q.saveObject hId' objType bytes'
                error "todo: optionally copy watch cache entry"
                error "todo: sync dependency index rows"
                error "todo: sync type/mentions index rows"
                error "todo"
                pure $ Right oId'
          OT.DeclComponent -> error "todo"
          OT.Namespace -> error "todo"
          OT.Patch -> error "todo"
        case result of
          Left deps -> pure . Sync.Missing $ toList deps
          Right oId' -> do
            syncSecondaryHashes oId oId'
            Cache.insert oCache oId oId'
            pure Sync.Done
  where
    foldLocalIds :: Either (Seq Entity) (Seq L.LocalIds) -> L.LocalIds -> m (Either (Seq Entity) (Seq L.LocalIds))
    foldLocalIds (Left missing) (L.LocalIds _tIds oIds) =
      syncLocalObjectIds oIds <&> \case
        Left missing2 -> Left (missing <> missing2)
        Right _oIds' -> Left missing
    foldLocalIds (Right localIdss') (L.LocalIds tIds oIds) =
      syncLocalObjectIds oIds >>= \case
        Left missing -> pure $ Left missing
        Right oIds' -> do
          tIds' <- traverse syncTextLiteral tIds
          pure $ Right (localIdss' Seq.|> L.LocalIds tIds' oIds')

    -- I want to collect all the failures, rather than short-circuiting after the first
    syncLocalObjectIds :: Traversable t => t ObjectId -> m (Either (Seq Entity) (t ObjectId))
    syncLocalObjectIds oIds = do
      (mayOIds', missing) <- Writer.runWriterT do
        for oIds \oId ->
          lift (isSyncedObject oId) >>= \case
            Just oId' -> pure oId'
            Nothing -> do
              Writer.tell . Seq.singleton $ O oId
              pure $ error "Arya didn't think this would get eval'ed."
      if null missing
        then pure $ Right mayOIds'
        else pure $ Left missing

    syncTextLiteral :: TextId -> m TextId
    syncTextLiteral = Cache.apply tCache \tId -> do
      t <- runSrc $ Q.loadTextById tId
      runDest $ Q.saveText t

    syncHashLiteral :: HashId -> m HashId
    syncHashLiteral = Cache.apply hCache \hId -> do
      b32hex <- runSrc $ Q.loadHashById hId
      runDest $ Q.saveHash b32hex

    syncCausalHash :: CausalHashId -> m CausalHashId
    syncCausalHash = fmap CausalHashId . syncHashLiteral . unCausalHashId

    syncBranchHashId :: BranchHashId -> m BranchHashId
    syncBranchHashId = fmap BranchHashId . syncHashLiteral . unBranchHashId

    findMissingParents :: CausalHashId -> m [Entity]
    findMissingParents chId = do
      runSrc (Q.loadCausalParents chId)
        >>= filterM isMissing
        <&> fmap C
      where
        isMissing p =
          syncCausalHash p
            >>= runDest . Q.isCausalHash . unCausalHashId

    syncSecondaryHashes oId oId' =
      runSrc (Q.hashIdWithVersionForObject oId) >>= traverse_ (go oId')
      where
        go oId' (hId, hashVersion) = do
          hId' <- syncHashLiteral hId
          runDest $ Q.saveHashObject hId' oId' hashVersion

    isSyncedObject :: ObjectId -> m (Maybe ObjectId)
    isSyncedObject = Cache.applyDefined oCache \oId -> do
      hIds <- toList <$> runSrc (Q.hashIdsForObject oId)
      ( nubOrd . catMaybes
          <$> traverse (runDest . Q.maybeObjectIdForAnyHashId) hIds
        )
        >>= \case
          [oId'] -> pure $ Just oId'
          [] -> pure $ Nothing
          oIds' -> throwError (HashObjectCorrespondence oId hIds oIds')

-- syncCausal chId = do
--   value

-- Q: Do we want to cache corresponding ID mappings?
-- A: Yes, but not yet

runSrc ::
  (MonadError Error m, MonadReader Env m) =>
  ReaderT Connection (ExceptT Q.Integrity m) a ->
  m a
runSrc = error "todo" -- withExceptT SrcDB . (reader fst >>=)

runDest ::
  (MonadError Error m, MonadReader Env m) =>
  ReaderT Connection (ExceptT Q.Integrity m) a ->
  m a
runDest = error "todo" -- withExceptT SrcDB . (reader fst >>=)

-- applyDefined

-- syncs coming from git:
--  - pull a specified remote causal (Maybe CausalHash) into the local database
--  - and then maybe do some stuff
-- syncs coming from