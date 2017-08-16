{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

-- | Wallet info modifier

module Pos.Wallet.Web.Tracking.Modifier
       ( CAccModifier (..)
       , CachedCAccModifier

       , VoidModifier
       , deleteAndInsertVM
       , deleteAndInsertMM

       , IndexedMapModifier (..)
       , sortedInsertions
       , indexedDeletions
       , insertIMM
       , deleteIMM
       , deleteAndInsertIMM
       ) where

import           Universum

import           Data.DList                 (DList)
import qualified Data.Text.Buildable
import           Formatting                 (bprint, build, (%))
import           Serokell.Util              (listJson, listJsonIndent)

import           Pos.Client.Txp.History     (TxHistoryEntry (..))
import           Pos.Core                   (HeaderHash)
import           Pos.Txp.Core               (TxId)
import           Pos.Txp.Toil               (UtxoModifier)
import           Pos.Util.Modifier          (MapModifier)
import qualified Pos.Util.Modifier          as MM

import           Pos.Wallet.Web.ClientTypes (Addr, CId, CWAddressMeta)

-- VoidModifier describes a difference between two states.
-- It's (set of added k, set of deleted k) essentially.
type VoidModifier a = MapModifier a ()

data IndexedMapModifier a = IndexedMapModifier
    { immModifier :: MM.MapModifier a Int
    , immCounter  :: Int
    }

sortedInsertions :: IndexedMapModifier a -> [a]
sortedInsertions = map fst . sortWith snd . MM.insertions . immModifier

indexedDeletions :: IndexedMapModifier a -> [a]
indexedDeletions = MM.deletions . immModifier

instance (Eq a, Hashable a) => Monoid (IndexedMapModifier a) where
    mempty = IndexedMapModifier mempty 0
    IndexedMapModifier m1 c1 `mappend` IndexedMapModifier m2 c2 =
        IndexedMapModifier (m1 <> fmap (+ c1) m2) (c1 + c2)

data CAccModifier = CAccModifier
    { camAddresses      :: !(IndexedMapModifier CWAddressMeta)
    , camUsed           :: !(VoidModifier (CId Addr, HeaderHash))
    , camChange         :: !(VoidModifier (CId Addr, HeaderHash))
    , camUtxo           :: !UtxoModifier
    , camAddedHistory   :: !(DList TxHistoryEntry)
    , camDeletedHistory :: !(DList TxId)
    }

instance Monoid CAccModifier where
    mempty = CAccModifier mempty mempty mempty mempty mempty mempty
    (CAccModifier a b c d ah dh) `mappend` (CAccModifier a1 b1 c1 d1 ah1 dh1) =
        CAccModifier (a <> a1) (b <> b1) (c <> c1) (d <> d1) (ah1 <> ah) (dh <> dh1)

instance Buildable CAccModifier where
    build CAccModifier{..} =
        bprint
            ( "\n    added addresses: "%listJsonIndent 8
            %",\n    deleted addresses: "%listJsonIndent 8
            %",\n    used addresses: "%listJson
            %",\n    change addresses: "%listJson
            %",\n    local utxo (difference): "%build
            %",\n    added history entries: "%listJsonIndent 8
            %",\n    deleted history entries: "%listJsonIndent 8)
        (sortedInsertions camAddresses)
        (indexedDeletions camAddresses)
        (map (fst . fst) $ MM.insertions camUsed)
        (map (fst . fst) $ MM.insertions camChange)
        camUtxo
        camAddedHistory
        camDeletedHistory

-- | `txMempoolToModifier`, once evaluated, is passed around under this type in
-- scope of single request.
type CachedCAccModifier = CAccModifier

----------------------------------------------------------------------------
-- Funcs
----------------------------------------------------------------------------

insertIMM
    :: (Eq a, Hashable a)
    => a -> IndexedMapModifier a -> IndexedMapModifier a
insertIMM k IndexedMapModifier {..} =
    IndexedMapModifier
    { immModifier = MM.insert k immCounter immModifier
    , immCounter  = immCounter + 1
    }

deleteIMM
    :: (Eq a, Hashable a)
    => a -> IndexedMapModifier a -> IndexedMapModifier a
deleteIMM k IndexedMapModifier {..} =
    IndexedMapModifier
    { immModifier = MM.delete k immModifier
    , ..
    }

deleteAndInsertIMM
    :: (Eq a, Hashable a)
    => [a] -> [a] -> IndexedMapModifier a -> IndexedMapModifier a
deleteAndInsertIMM dels ins mapModifier =
    -- Insert CWAddressMeta coressponding to outputs of tx.
    (\mm -> foldl' (flip insertIMM) mm ins) $
    -- Delete CWAddressMeta coressponding to inputs of tx.
    foldl' (flip deleteIMM) mapModifier dels

deleteAndInsertVM :: (Eq a, Hashable a) => [a] -> [a] -> VoidModifier a -> VoidModifier a
deleteAndInsertVM dels ins mapModifier = deleteAndInsertMM dels (zip ins $ repeat ()) mapModifier

deleteAndInsertMM :: (Eq k, Hashable k) => [k] -> [(k, v)] -> MM.MapModifier k v -> MM.MapModifier k v
deleteAndInsertMM dels ins mapModifier =
    -- Insert CWAddressMeta coressponding to outputs of tx (2)
    (\mm -> foldl' insertAcc mm ins) $
    -- Delete CWAddressMeta coressponding to inputs of tx (1)
    foldl' deleteAcc mapModifier dels
  where
    insertAcc :: (Hashable k, Eq k) => MapModifier k v -> (k, v) -> MapModifier k v
    insertAcc modifier (k, v) = MM.insert k v modifier

    deleteAcc :: (Hashable k, Eq k) => MapModifier k v -> k -> MapModifier k v
    deleteAcc = flip MM.delete

