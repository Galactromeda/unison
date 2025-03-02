{- ORMOLU_DISABLE -} -- Remove this when the file is ready to be auto-formatted
{-# OPTIONS_GHC -Wno-partial-type-signatures #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Unison.Codebase.Editor.Propagate (propagateAndApply) where

import           Control.Error.Util             ( hush )
import           Control.Lens
import           Data.Configurator              ( )
import qualified Data.Graph                    as Graph
import qualified Data.Map                      as Map
import qualified Data.Set                      as Set
import           Unison.Codebase.Branch         ( Branch0(..) )
import           Unison.Prelude
import qualified Unison.Codebase.Branch        as Branch
import qualified Unison.Codebase.Branch.Names as Branch
import           Unison.Codebase.Editor.Command
import           Unison.Codebase.Editor.Output
import           Unison.Codebase.Patch          ( Patch(..) )
import qualified Unison.Codebase.Patch         as Patch
import Unison.ConstructorReference (GConstructorReference(..))
import           Unison.DataDeclaration         ( Decl )
import qualified Unison.DataDeclaration        as Decl
import qualified Unison.Name                   as Name
import           Unison.Names                  ( Names )
import qualified Unison.Names                 as Names
import Unison.Parser.Ann (Ann(..))
import           Unison.Reference               ( Reference(..) )
import qualified Unison.Reference              as Reference
import           Unison.Referent                ( Referent )
import qualified Unison.Referent               as Referent
import qualified Unison.Result                 as Result
import qualified Unison.Term                   as Term
import           Unison.Term                    ( Term )
import           Unison.Util.Free               ( Free
                                                , eval
                                                )
import           Unison.Util.Monoid             ( foldMapM )
import qualified Unison.Util.Relation          as R
import           Unison.Util.TransitiveClosure  ( transitiveClosure )
import           Unison.Var                     ( Var )
import qualified Unison.Codebase.Metadata      as Metadata
import qualified Unison.Codebase.TypeEdit      as TypeEdit
import           Unison.Codebase.TermEdit       ( TermEdit(..) )
import qualified Unison.Codebase.TermEdit      as TermEdit
import qualified Unison.Codebase.TermEdit.Typing as TermEdit
import           Unison.Codebase.TypeEdit       ( TypeEdit(..) )
import           Unison.UnisonFile              ( UnisonFile(..) )
import qualified Unison.UnisonFile             as UF
import qualified Unison.Util.Star3             as Star3
import           Unison.Type                    ( Type )
import qualified Unison.Typechecker            as Typechecker
import qualified Unison.Runtime.IOSource       as IOSource
import qualified Unison.Hashing.V2.Convert as Hashing
import Unison.WatchKind (WatchKind)

type F m i v = Free (Command m i v)

data Edits v = Edits
  { termEdits :: Map Reference TermEdit
  -- same info as `termEdits` but in more efficient form for calling `Term.updateDependencies`
  , termReplacements :: Map Referent Referent
  , newTerms :: Map Reference (Term v Ann, Type v Ann)
  , typeEdits :: Map Reference TypeEdit
  , typeReplacements :: Map Reference Reference
  , newTypes :: Map Reference (Decl v Ann)
  , constructorReplacements :: Map Referent Referent
  } deriving (Eq, Show)

noEdits :: Edits v
noEdits = Edits mempty mempty mempty mempty mempty mempty mempty

propagateAndApply
  :: forall m i v
   . (Applicative m, Var v)
  => Names
  -> Patch
  -> Branch0 m
  -> F m i v (Branch0 m)
propagateAndApply rootNames patch branch = do
  edits <- propagate rootNames patch branch
  f     <- applyPropagate patch edits
  (pure . f . applyDeprecations patch) branch


-- This function produces constructor mappings for propagated type updates.
--
-- For instance in `type Foo = Blah Bar | Zoink Nat`, if `Bar` is updated
-- from `Bar#old` to `Bar#new`, `Foo` will be a "propagated update" and
-- we want to map the `Foo#old.Blah` constructor to `Foo#new.Blah`.
--
-- The function works by aligning same-named types and same-named constructors,
-- using the names of the types provided by the two maps and the names
-- of constructors embedded in the data decls themselves.
--
-- This is correct, and relies only on the type and constructor names coming
-- out of the codebase and Decl.unhashComponent being unique, which they are.
--
-- What happens is that the declaration component is pulled out of the codebase,
-- references are converted back to variables, substitutions are made in
-- constructor type signatures, and then the component is rehashed, which
-- re-canonicalizes the constructor orders in a possibly different way.
--
-- The unique names for the types and constructors are just carried through
-- unchanged through this process, so their being the same establishes that they
-- had the same role in the two versions of the cycle.
propagateCtorMapping
  :: (Var v, Show a)
  => Map v (Reference, Decl v a)
  -> Map v (Reference, Decl.DataDeclaration v a)
  -> Map Referent Referent
propagateCtorMapping oldComponent newComponent = let
  singletons = Map.size oldComponent == 1 && Map.size newComponent == 1
  isSingleton c = null . drop 1 $ Decl.constructors' c
  r = Map.fromList
    [ (oldCon, newCon)
    | (v1, (oldR, oldDecl)) <- Map.toList oldComponent
    , (v2, (newR, newDecl)) <- Map.toList newComponent
    , v1 == v2 || singletons
    , let t = Decl.constructorType oldDecl
    , (oldC, (_,ol'Name,_)) <- zip [0 ..] $ Decl.constructors' (Decl.asDataDecl oldDecl)
    , (newC, (_,newName,_)) <- zip [0 ..] $ Decl.constructors' newDecl
    , ol'Name == newName || (isSingleton (Decl.asDataDecl oldDecl) && isSingleton newDecl)
    , oldR /= newR
    , let oldCon = Referent.Con (ConstructorReference oldR oldC) t
          newCon = Referent.Con (ConstructorReference newR newC) t
    ]
  in if debugMode then traceShow ("constructorMappings", r) r else r


-- TODO: Use of this function will go away soon, once constructor mappings can be
-- added directly to the patch.
--
-- Given a set of type replacements, this creates a mapping from the constructors
-- of the old type(s) to the constructors of the new types.
--
-- Constructors for the same-unqualified-named type with a same-unqualified-name
-- constructor are mapped to each other.
--
-- If the cycle is size 1 for old and new, then the type names need not be the same,
-- and if the number of constructors is 1, then the constructor names need not
-- be the same.
genInitialCtorMapping ::
  forall v m i . Var v => Names -> Map Reference Reference -> F m i v (Map Referent Referent)
genInitialCtorMapping rootNames initialTypeReplacements = do
  let mappings :: (Reference,Reference) -> _ (Map Referent Referent)
      mappings (old,new) = do
        old <- unhashTypeComponent old
        new <- fmap (over _2 (either Decl.toDataDecl id)) <$> unhashTypeComponent new
        pure $ ctorMapping old new
  Map.unions <$> traverse mappings (Map.toList initialTypeReplacements)
  where
  -- True if the unqualified versions of the names in the two sets overlap
  -- ex: {foo.bar, foo.baz} matches the set {blah.bar}.
  unqualifiedNamesMatch :: Set Name.Name -> Set Name.Name -> Bool
  unqualifiedNamesMatch n1 n2 | debugMode && traceShow ("namesMatch", n1, n2) False = undefined
  unqualifiedNamesMatch n1 n2 =
    (not . Set.null) (Set.intersection (Set.map Name.unqualified n1)
                                       (Set.map Name.unqualified n2))
  ctorNamesMatch oldR newR =
    unqualifiedNamesMatch (Names.namesForReferent rootNames oldR)
                          (Names.namesForReferent rootNames newR)

  typeNamesMatch typeMapping oldType newType =
    Map.lookup oldType typeMapping == Just newType ||
    unqualifiedNamesMatch (Names.namesForReference rootNames oldType)
                          (Names.namesForReference rootNames oldType)

  ctorMapping
    :: Map v (Reference, Decl v a)
    -> Map v (Reference, Decl.DataDeclaration v a)
    -> Map Referent Referent
  ctorMapping oldComponent newComponent = let
    singletons = Map.size oldComponent == 1 && Map.size newComponent == 1
    isSingleton c = null . drop 1 $ Decl.constructors' c
    r = Map.fromList
      [ (oldCon, newCon)
      | (_, (oldR, oldDecl)) <- Map.toList oldComponent
      , (_, (newR, newDecl)) <- Map.toList newComponent
      , typeNamesMatch initialTypeReplacements oldR newR || singletons
      , let t = Decl.constructorType oldDecl
      , (oldC, _) <- zip [0 ..] $ Decl.constructors' (Decl.asDataDecl oldDecl)
      , (newC, _) <- zip [0 ..] $ Decl.constructors' newDecl
      , let oldCon = Referent.Con (ConstructorReference oldR oldC) t
            newCon = Referent.Con (ConstructorReference newR newC) t
      , ctorNamesMatch oldCon newCon
        || (isSingleton (Decl.asDataDecl oldDecl) && isSingleton newDecl)
      , oldR /= newR
      ]
    in if debugMode then traceShow ("constructorMappings", r) r else r

debugMode :: Bool
debugMode = False

-- Note: this function adds definitions to the codebase as it propagates.
-- Description:
------------------
-- For any `Reference` in the frontier which has an unconflicted
-- term edit, `old -> new`, replace `old` with `new` in dependents of the
-- frontier, and call `propagate'` recursively on the new frontier if
-- the dependents still typecheck.
--
-- If the term is `Typing.Same`, the dependents don't need to be typechecked.
-- If the term is `Typing.Subtype`, and the dependent only has inferred type,
-- it should be re-typechecked, and the new inferred type should be used.
--
-- This will create a whole bunch of new terms and types in the codebase and
-- move the names onto those new terms. Uses `updateDependencies` to perform
-- the substitutions.
--
-- Algorithm:
----------------
-- compute the frontier relation (dependencies of updated terms and types)
-- for each dirty definition d:
--  for each member c of cycle(d):
--   construct c', an updated c incorporating all edits
--   Add an edit c -> c'
--     and save c' to a `Map Reference Term` or `Map Reference Type`
--     as appropriate
--   Collect all c' into a new cycle and typecheck (TODO: kindcheck) that cycle.
--     If the cycle doesn't check, discard edits to that cycle.
--
-- "dirty" means in need of update
-- "frontier" means updated definitions responsible for the "dirty"
propagate
  :: forall m i v
   . (Applicative m, Var v)
  => Names -- TODO: this argument can be removed once patches have term replacement
            -- of type `Referent -> Referent`
  -> Patch
  -> Branch0 m
  -> F m i v (Edits v)
propagate rootNames patch b = case validatePatch patch of
  Nothing -> do
    eval $ Notify PatchNeedsToBeConflictFree
    pure noEdits
  Just (initialTermEdits, initialTypeEdits) -> do
    let
      entireBranch = Set.union
        (Branch.deepTypeReferences b)
        (Set.fromList
          [ r | Referent.Ref r <- Set.toList $ Branch.deepReferents b ]
        )

      -- TODO: these are just used for tracing, could be deleted if we don't care
      -- about printing meaningful names for definitions during propagation, or if
      -- we want to just remove the tracing.
      refName r = -- could just become show r if we don't care
        let rns = Names.namesForReferent rootNames (Referent.Ref r)
               <> Names.namesForReference rootNames r
        in case toList rns of
          [] -> show r
          n : _ -> show n
      -- this could also become show r if we're removing the dependency on Names
      referentName r = case toList (Names.namesForReferent rootNames r) of
        [] -> Referent.toString r
        n : _ -> show n

    initialDirty <- computeDirty (eval . GetDependents) patch names0

    let initialTypeReplacements = Map.mapMaybe TypeEdit.toReference initialTypeEdits
    -- TODO: once patches can directly contain constructor replacements, this
    -- line can turn into a pure function that takes the subset of the term replacements
    -- in the patch which have a `Referent.Con` as their LHS.
    initialCtorMappings <- genInitialCtorMapping rootNames initialTypeReplacements

    order <- sortDependentsGraph initialDirty entireBranch
    let

      getOrdered :: Set Reference -> Map Int Reference
      getOrdered rs =
        Map.fromList [ (i, r) | r <- toList rs, Just i <- [Map.lookup r order] ]
      collectEdits
        :: (Applicative m, Var v)
        => Edits v
        -> Set Reference
        -> Map Int Reference
        -> F m i v (Edits v)
      collectEdits es@Edits {..} seen todo = case Map.minView todo of
        Nothing        -> pure es
        Just (r, todo) -> case r of
          Reference.Builtin   _ -> collectEdits es seen todo
          Reference.DerivedId _ -> go r todo
       where
        debugCtors =
          unlines [ referentName old <> " -> " <> referentName new
                  | (old,new) <- Map.toList constructorReplacements ]
        go r _ | debugMode && traceShow ("Rewriting: ", refName r) False = undefined
        go _ _ | debugMode && trace ("** Constructor replacements:\n\n" <> debugCtors) False = undefined
        go r todo =
          if Map.member r termEdits || Set.member r seen || Map.member r typeEdits
          then collectEdits es seen todo
          else
            do
              haveType <- eval $ IsType r
              haveTerm <- eval $ IsTerm r
              let message =
                    "This reference is not a term nor a type " <> show r
                  mmayEdits | haveTerm  = doTerm r
                            | haveType  = doType r
                            | otherwise = error message
              mayEdits <- mmayEdits
              case mayEdits of
                (Nothing    , seen') -> collectEdits es seen' todo
                (Just edits', seen') -> do
                  -- plan to update the dependents of this component too
                  dependents <-
                    fmap Set.unions
                    . traverse (eval . GetDependents)
                    . toList
                    . Reference.members
                    $ Reference.componentFor r
                  let todo' = todo <> getOrdered dependents
                  collectEdits edits' seen' todo'

        doType :: Reference -> F m i v (Maybe (Edits v), Set Reference)
        doType r = do
          when debugMode $ traceM ("Rewriting type: " <> refName r)
          componentMap <- unhashTypeComponent r
          let componentMap' =
                over _2 (Decl.updateDependencies typeReplacements)
                  <$> componentMap
              declMap = over _2 (either Decl.toDataDecl id) <$> componentMap'
              -- TODO: kind-check the new components
              hashedDecls = (fmap . fmap) (over _2 DerivedId)
                          . Hashing.hashDecls
                          $ view _2 <$> declMap
          hashedComponents' <- case hashedDecls of
            Left _ ->
              error
                $ "Edit propagation failed because some of the dependencies of "
                <> show r
                <> " could not be resolved."
            Right c -> pure . Map.fromList $ (\(v, r, d) -> (v, (r, d))) <$> c
          let
            -- Relation: (nameOfType, oldRef, newRef, newType)
            joinedStuff
              :: [(v, (Reference, Reference, Decl.DataDeclaration v _))]
            joinedStuff =
              Map.toList (Map.intersectionWith f declMap hashedComponents')
            f (oldRef, _) (newRef, newType) = (oldRef, newRef, newType)
            typeEdits' = typeEdits <> (Map.fromList . fmap toEdit) joinedStuff
            toEdit (_, (r, r', _)) = (r, TypeEdit.Replace r')
            typeReplacements' = typeReplacements
              <> (Map.fromList . fmap toReplacement) joinedStuff
            toReplacement (_, (r, r', _)) = (r, r')
            -- New types this iteration
            newNewTypes = (Map.fromList . fmap toNewType) joinedStuff
            -- Accumulated new types
            newTypes' = newTypes <> newNewTypes
            toNewType (v, (_, r', tp)) =
              ( r'
              , case Map.lookup v componentMap of
                Just (_, Left _ ) -> Left (Decl.EffectDeclaration tp)
                Just (_, Right _) -> Right tp
                _                 -> error "It's not gone well!"
              )
            seen' = seen <> Set.fromList (view _1 . view _2 <$> joinedStuff)
            writeTypes =
              traverse_ (\(Reference.DerivedId id, tp) -> eval $ PutDecl id tp)
            !newCtorMappings = let
              r = propagateCtorMapping componentMap hashedComponents'
              in if debugMode then traceShow ("constructorMappings: ", r) r else r
            constructorReplacements' = constructorReplacements <> newCtorMappings
          writeTypes $ Map.toList newNewTypes
          pure
            ( Just $ Edits termEdits
                           (newCtorMappings <> termReplacements)
                           newTerms
                           typeEdits'
                           typeReplacements'
                           newTypes'
                           constructorReplacements'
            , seen'
            )
        doTerm :: Reference -> F m i v (Maybe (Edits v), Set Reference)
        doTerm r = do
          when debugMode (traceM $ "Rewriting term: " <> show r)
          componentMap <- unhashTermComponent r
          let componentMap' =
                over
                    _2
                    (Term.updateDependencies termReplacements typeReplacements)
                  <$> componentMap
              seen' = seen <> Set.fromList (view _1 <$> Map.elems componentMap)
          mayComponent <- verifyTermComponent componentMap' es
          case mayComponent of
            Nothing             -> do
              when debugMode (traceM $ refName r <> " did not typecheck after substitutions")
              pure (Nothing, seen')
            Just componentMap'' -> do
              let
                joinedStuff =
                  toList (Map.intersectionWith f componentMap componentMap'')
                f (oldRef, _oldTerm, oldType) (newRef, _newWatchKind, newTerm, newType) =
                  (oldRef, newRef, newTerm, oldType, newType')
                    -- Don't replace the type if it hasn't changed.

                 where
                  newType' | Typechecker.isEqual oldType newType = oldType
                           | otherwise                           = newType
            -- collect the hashedComponents into edits/replacements/newterms/seen
                termEdits' =
                  termEdits <> (Map.fromList . fmap toEdit) joinedStuff
                toEdit (r, r', _newTerm, oldType, newType) =
                  (r, TermEdit.Replace r' $ TermEdit.typing newType oldType)
                termReplacements' = termReplacements
                  <> (Map.fromList . fmap toReplacement) joinedStuff
                toReplacement (r, r', _, _, _) = (Referent.Ref r, Referent.Ref r')
                newTerms' =
                  newTerms <> (Map.fromList . fmap toNewTerm) joinedStuff
                toNewTerm (_, r', tm, _, tp) = (r', (tm, tp))
                writeTerms =
                  traverse_
                    (\(Reference.DerivedId id, (tm, tp)) ->
                      eval $ PutTerm id tm tp
                    )
              writeTerms
                [ (r, (tm, ty)) | (_old, r, tm, _oldTy, ty) <- joinedStuff ]
              pure
                ( Just $ Edits termEdits'
                               termReplacements'
                               newTerms'
                               typeEdits
                               typeReplacements
                               newTypes
                               constructorReplacements
                , seen'
                )
    collectEdits
      (Edits initialTermEdits
             (initialTermReplacements initialCtorMappings initialTermEdits)
             mempty
             initialTypeEdits
             initialTypeReplacements
             mempty
             initialCtorMappings
      )
      mempty -- things to skip
      (getOrdered initialDirty)
 where
  initialTermReplacements ctors es = ctors <>
    (Map.mapKeys Referent.Ref . fmap Referent.Ref . Map.mapMaybe TermEdit.toReference) es
  sortDependentsGraph :: Set Reference -> Set Reference -> _ (Map Reference Int)
  sortDependentsGraph dependencies restrictTo = do
    closure <- transitiveClosure
      (fmap (Set.intersection restrictTo) . eval . GetDependents)
      dependencies
    dependents <- traverse (\r -> (r, ) <$> (eval . GetDependents) r)
                           (toList closure)
    let graphEdges = [ (r, r, toList deps) | (r, deps) <- toList dependents ]
        (graph, getReference, _) = Graph.graphFromEdges graphEdges
    pure $ Map.fromList
      (zip (view _1 . getReference <$> Graph.topSort graph) [0 ..])
    -- vertex i precedes j whenever i has an edge to j and not vice versa.
    -- vertex i precedes j when j is a dependent of i.
  names0 = Branch.toNames b
  validatePatch
    :: Patch -> Maybe (Map Reference TermEdit, Map Reference TypeEdit)
  validatePatch p =
    (,) <$> R.toMap (Patch._termEdits p) <*> R.toMap (Patch._typeEdits p)
  -- Turns a cycle of references into a term with free vars that we can edit
  -- and hash again.
  -- todo: Maybe this an others can be moved to HandleCommand, in the
  --  Free (Command m i v) monad, passing in the actions that are needed.
  -- However, if we want this to be parametric in the annotation type, then
  -- Command would have to be made parametric in the annotation type too.
  unhashTermComponent
    :: forall m v
     . (Applicative m, Var v)
    => Reference
    -> F m i v (Map v (Reference, Term v _, Type v _))
  unhashTermComponent ref = do
    let component = Reference.members $ Reference.componentFor ref
        termInfo
          :: Reference -> F m i v (Maybe (Reference, (Term v Ann, Type v Ann)))
        termInfo termRef = do
          tpm <- eval $ LoadTypeOfTerm termRef
          tp  <- maybe (error $ "Missing type for term " <> show termRef)
                       pure
                       tpm
          case termRef of
            Reference.DerivedId id -> do
              mtm <- eval $ LoadTerm id
              tm  <- maybe (error $ "Missing term with id " <> show id) pure mtm
              pure $ Just (termRef, (tm, tp))
            Reference.Builtin{} -> pure Nothing
        unhash m =
          let f (_oldTm, oldTyp) (v, newTm) = (v, newTm, oldTyp)
              m' = Map.intersectionWith f m (Term.unhashComponent (fst <$> m))
          in  Map.fromList
                [ (v, (r, tm, tp)) | (r, (v, tm, tp)) <- Map.toList m' ]
    unhash . Map.fromList . catMaybes <$> traverse termInfo (toList component)
  verifyTermComponent
    :: Map v (Reference, Term v _, a)
    -> Edits v
    -> F m i v (Maybe (Map v (Reference, Maybe WatchKind, Term v _, Type v _)))
  verifyTermComponent componentMap Edits {..} = do
    -- If the term contains references to old patterns, we can't update it.
    -- If the term had a redunant type signature, it's discarded and a new type
    -- is inferred. If it wasn't redunant, we have already substituted any updates
    -- into it and we're going to check against that signature.
    --
    -- Note: This only works if the type update is kind-preserving.
    let
      -- See if the constructor dependencies of any element of the cycle
      -- contains one of the old types.
        terms    = Map.elems $ view _2 <$> componentMap
        oldTypes = Map.keysSet typeEdits
    if not . Set.null $ Set.intersection
         (foldMap Term.constructorDependencies terms)
         oldTypes
      then pure Nothing
      else do
        let file = UnisonFileId
              mempty
              mempty
              (Map.toList $ (\(_, tm, _) -> tm) <$> componentMap)
              mempty
        typecheckResult <- eval $ TypecheckFile file []
        pure
          .   fmap UF.hashTerms
          $   runIdentity (Result.toMaybe typecheckResult)
          >>= hush

unhashTypeComponent :: Var v => Reference -> F m i v (Map v (Reference, Decl v Ann))
unhashTypeComponent ref = do
  let
    component = Reference.members $ Reference.componentFor ref
    typeInfo :: Reference -> F m i v (Maybe (Reference, Decl v Ann))
    typeInfo typeRef = case typeRef of
      Reference.DerivedId id -> do
        declm <- eval $ LoadType id
        decl  <- maybe (error $ "Missing type declaration " <> show typeRef)
                       pure
                       declm
        pure $ Just (typeRef, decl)
      Reference.Builtin{} -> pure Nothing
    unhash =
      Map.fromList . map reshuffle . Map.toList . Decl.unhashComponent
      where reshuffle (r, (v, decl)) = (v, (r, decl))
  unhash . Map.fromList . catMaybes <$> traverse typeInfo (toList component)

applyDeprecations :: Applicative m => Patch -> Branch0 m -> Branch0 m
applyDeprecations patch = deleteDeprecatedTerms deprecatedTerms
  . deleteDeprecatedTypes deprecatedTypes
 where
  deprecatedTerms, deprecatedTypes :: Set Reference
  deprecatedTerms = Set.fromList
    [ r | (r, TermEdit.Deprecate) <- R.toList (Patch._termEdits patch) ]
  deprecatedTypes = Set.fromList
    [ r | (r, TypeEdit.Deprecate) <- R.toList (Patch._typeEdits patch) ]
  deleteDeprecatedTerms, deleteDeprecatedTypes
    :: Set Reference -> Branch0 m -> Branch0 m
  deleteDeprecatedTerms rs =
    over Branch.terms (Star3.deleteFact (Set.map Referent.Ref rs))
  deleteDeprecatedTypes rs = over Branch.types (Star3.deleteFact rs)

-- | Things in the patch are not marked as propagated changes, but every other
-- definition that is created by the `Edits` which is passed in is marked as
-- a propagated change.
applyPropagate
  :: Var v => Applicative m => Patch -> Edits v -> F m i v (Branch0 m -> Branch0 m)
applyPropagate patch Edits {..} = do
  let termTypes = Map.map (Hashing.typeToReference . snd) newTerms
  -- recursively update names and delete deprecated definitions
  pure $ Branch.stepEverywhere (updateLevel termReplacements typeReplacements termTypes)
 where
  isPropagated r = Set.notMember r allPatchTargets
  allPatchTargets = Patch.allReferenceTargets patch
  propagatedMd :: forall r . r -> (r, Metadata.Type, Metadata.Value)
  propagatedMd r = (r, IOSource.isPropagatedReference, IOSource.isPropagatedValue)

  updateLevel
    :: Map Referent Referent
    -> Map Reference Reference
    -> Map Reference Reference
    -> Branch0 m
    -> Branch0 m
  updateLevel termEdits typeEdits termTypes Branch0 {..} =
    Branch.branch0 terms types _children _edits
   where
    isPropagatedReferent (Referent.Con _ _) = True
    isPropagatedReferent (Referent.Ref r) = isPropagated r

    terms0 = Star3.replaceFacts replaceConstructor constructorReplacements _terms
    terms = updateMetadatas Referent.Ref
          $ Star3.replaceFacts replaceTerm termEdits terms0
    types = updateMetadatas id
          $ Star3.replaceFacts replaceType typeEdits _types

    updateMetadatas ref s = clearPropagated $ Star3.mapD3 go s
      where
      clearPropagated s = foldl' go s allPatchTargets where
        go s r = Metadata.delete (propagatedMd $ ref r) s
      go (tp,v) = case Map.lookup (Referent.Ref v) termEdits of
        Just (Referent.Ref r) -> (typeOf r tp, r)
        _ -> (tp,v)
      typeOf r t = fromMaybe t $ Map.lookup r termTypes

    replaceTerm :: Referent -> Referent -> _ -> _
    replaceTerm r r' s =
      (if isPropagatedReferent r'
       then Metadata.insert (propagatedMd r') . Metadata.delete (propagatedMd r)
       else Metadata.delete (propagatedMd r')) $ s

    replaceConstructor :: Referent -> Referent -> _ -> _
    replaceConstructor (Referent.Con _ _) !new s =
      -- TODO: revisit this once patches have constructor mappings
      -- at the moment, all constructor replacements are autopropagated
      -- rather than added manually
      Metadata.insert (propagatedMd new) $ s
    replaceConstructor _ _ s = s

    replaceType _ r' s =
      (if isPropagated r' then Metadata.insert (propagatedMd r')
       else Metadata.delete (propagatedMd r')) $ s

  -- typePreservingTermEdits :: Patch -> Patch
  -- typePreservingTermEdits Patch {..} = Patch termEdits mempty
  --   where termEdits = R.filterRan TermEdit.isTypePreserving _termEdits

-- | Compute the set of "dirty" references. They each:
--
--   1. Depend directly on some reference that was edited in the given patch
--   2. Have a name in the current namespace (the given Names)
--   3. Are not themselves edited in the given patch.
computeDirty
  :: forall m
   . Monad m
  => (Reference -> m (Set Reference)) -- eg Codebase.dependents codebase
  -> Patch
  -> Names
  -> m (Set Reference)
computeDirty getDependents patch names =
  foldMapM (\ref -> keepDirtyDependents <$> getDependents ref) edited
  where
  -- Given a set of dependent references (satisfying 1. above), keep only the dirty ones (per 2. and 3. above)
  keepDirtyDependents :: Set Reference -> Set Reference
  keepDirtyDependents =
    (`Set.difference` edited) . Set.filter (Names.contains names)

  edited :: Set Reference
  edited = R.dom (Patch._termEdits patch) <> R.dom (Patch._typeEdits patch)
