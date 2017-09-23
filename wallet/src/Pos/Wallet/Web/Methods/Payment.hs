{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

-- | Transaction creation and fees

module Pos.Wallet.Web.Methods.Payment
       ( newPayment
       , getTxFee
       ) where

import           Universum

import qualified Data.List.NonEmpty             as NE
import           Formatting                     (sformat, (%))
import qualified Formatting                     as F
import           System.Wlog                    (logInfo)

import           Pos.Aeson.ClientTypes          ()
import           Pos.Aeson.WalletBackup         ()
import           Pos.Client.Txp.Addresses       (MonadAddresses (..))
import           Pos.Client.Txp.Balances        (getOwnUtxos)
import           Pos.Client.Txp.History         (TxHistoryEntry (..))
import           Pos.Client.Txp.Util            (computeTxFee, runTxCreator)
import           Pos.Communication              (SendActions (..), prepareMTx)
import           Pos.Core                       (Coin, HasCoreConstants, addressF,
                                                 getCurrentTimestamp)
import           Pos.Crypto                     (PassPhrase, hash, withSafeSigners)
import           Pos.Txp                        (TxFee (..), Utxo, _txOutputs)
import           Pos.Txp.Core                   (TxAux (..), TxOut (..))
import           Pos.Util                       (eitherToThrow, maybeThrow)
import           Pos.Wallet.Web.Account         (AccountMode, GenSeed (..),
                                                 MonadKeySearch (..), getSKByAccAddr)
import           Pos.Wallet.Web.ClientTypes     (AccountId (..), Addr, CAddress (..),
                                                 CCoin, CId, CTx (..), CWAddressMeta (..),
                                                 Wal, addrMetaToAccount, mkCCoin)
import           Pos.Wallet.Web.Error           (WalletError (..))
import           Pos.Wallet.Web.Methods.History (addHistoryTx)
import qualified Pos.Wallet.Web.Methods.Logic   as L
import           Pos.Wallet.Web.Methods.Txp     (coinDistrToOutputs, rewrapTxError,
                                                 submitAndSaveNewPtx)
import           Pos.Wallet.Web.Mode            (MonadWalletWebMode, WalletWebMode)
import           Pos.Wallet.Web.Pending         (mkPendingTx)
import           Pos.Wallet.Web.State           (AddressLookupMode (Existing))
import           Pos.Wallet.Web.Tracking        (CAccModifier, fixingCachedAccModifier)
import           Pos.Wallet.Web.Util            (decodeCTypeOrFail, getWalletAccountIds)


newPayment
    :: MonadWalletWebMode m
    => SendActions m
    -> PassPhrase
    -> AccountId
    -> CId Addr
    -> Coin
    -> m CTx
newPayment sa passphrase srcAccount dstAccount coin =
    sendMoney
        sa
        passphrase
        (AccountMoneySource srcAccount)
        (one (dstAccount, coin))

getTxFee
     :: MonadWalletWebMode m
     => AccountId
     -> CId Addr
     -> Coin
     -> m CCoin
getTxFee srcAccount dstAccount coin = do
    utxo <- fixingCachedAccModifier getMoneySourceUtxo (AccountMoneySource srcAccount)
    outputs <- coinDistrToOutputs $ one (dstAccount, coin)
    TxFee fee <- rewrapTxError "Cannot compute transaction fee" $
        eitherToThrow =<< runTxCreator (computeTxFee utxo outputs)
    pure $ mkCCoin fee

data MoneySource
    = WalletMoneySource (CId Wal)
    | AccountMoneySource AccountId
    | AddressMoneySource CWAddressMeta
    deriving (Show, Eq)

instance AccountMode ctx m =>
         MonadKeySearch MoneySource m where
    findKey (WalletMoneySource wid)  = findKey wid
    findKey (AccountMoneySource aid) = findKey aid
    findKey (AddressMoneySource aid) = findKey aid

getMoneySourceAddresses
    :: MonadWalletWebMode m
    => CAccModifier -> MoneySource -> m [CWAddressMeta]
getMoneySourceAddresses _ (AddressMoneySource addrId) = return $ one addrId
getMoneySourceAddresses cmod (AccountMoneySource accId) =
    L.getActualAccountAddresses cmod Existing accId
getMoneySourceAddresses cmod (WalletMoneySource wid) =
    getWalletAccountIds wid >>=
    concatMapM (getMoneySourceAddresses cmod . AccountMoneySource)

getSomeMoneySourceAccount :: MonadWalletWebMode m => MoneySource -> m AccountId
getSomeMoneySourceAccount (AddressMoneySource addrId) =
    return $ addrMetaToAccount addrId
getSomeMoneySourceAccount (AccountMoneySource accId) = return accId
getSomeMoneySourceAccount (WalletMoneySource wid) = do
    wAddr <- (head <$> getWalletAccountIds wid) >>= maybeThrow noWallets
    getSomeMoneySourceAccount (AccountMoneySource wAddr)
  where
    noWallets = InternalError "Wallet has no accounts"

getMoneySourceWallet :: MoneySource -> CId Wal
getMoneySourceWallet (AddressMoneySource addrId) = cwamWId addrId
getMoneySourceWallet (AccountMoneySource accId)  = aiWId accId
getMoneySourceWallet (WalletMoneySource wid)     = wid

getMoneySourceUtxo
    :: MonadWalletWebMode m
    => CAccModifier -> MoneySource -> m Utxo
getMoneySourceUtxo cmod =
    getMoneySourceAddresses cmod >=>
    mapM (decodeCTypeOrFail . cwamId) >=>
    getOwnUtxos

-- [CSM-407] It should be moved to `Pos.Wallet.Web.Mode`, but
-- to make it possible all this mess should be neatly separated
-- to modules and refactored
instance HasCoreConstants => MonadAddresses Pos.Wallet.Web.Mode.WalletWebMode where
    type AddrData Pos.Wallet.Web.Mode.WalletWebMode = (AccountId, PassPhrase)
    getNewAddress (accId, passphrase) = do
        clientAddress <- L.newAddress RandomSeed passphrase accId
        decodeCTypeOrFail (cadId clientAddress)

sendMoney
    :: MonadWalletWebMode m
    => SendActions m
    -> PassPhrase
    -> MoneySource
    -> NonEmpty (CId Addr, Coin)
    -> m CTx
sendMoney SendActions{..} passphrase moneySource dstDistr = do
    addrMetas' <- fixingCachedAccModifier getMoneySourceAddresses moneySource
    addrMetas <- nonEmpty addrMetas' `whenNothing`
        throwM (RequestError "Given money source has no addresses!")
    sks <- forM addrMetas $ getSKByAccAddr passphrase
    srcAddrs <- forM addrMetas $ decodeCTypeOrFail . cwamId

    withSafeSigners sks (pure passphrase) $ \mss -> do
        ss <- maybeThrow (RequestError "Passphrase doesn't match") mss

        let hdwSigner = NE.zip ss srcAddrs
            srcWallet = getMoneySourceWallet moneySource

        relatedAccount <- getSomeMoneySourceAccount moneySource
        outputs <- coinDistrToOutputs dstDistr
        (th, dstAddrs) <-
            rewrapTxError "Cannot send transaction" $ do
                (txAux, inpTxOuts') <-
                    prepareMTx hdwSigner outputs (relatedAccount, passphrase)

                ts <- Just <$> getCurrentTimestamp
                let tx = taTx txAux
                    txHash = hash tx
                    inpTxOuts = toList inpTxOuts'
                    dstAddrs  = map txOutAddress . toList $
                                _txOutputs tx
                    th = THEntry txHash tx Nothing inpTxOuts dstAddrs ts
                ptx <- mkPendingTx srcWallet txHash txAux th

                (th, dstAddrs) <$ submitAndSaveNewPtx enqueueMsg ptx

        logInfo $
            sformat ("Successfully spent money from "%
                     listF ", " addressF % " addresses on " %
                     listF ", " addressF)
            (toList srcAddrs)
            dstAddrs

        addHistoryTx srcWallet th
  where
     -- TODO eliminate copy-paste
     listF separator formatter =
         F.later $ fold . intersperse separator . fmap (F.bprint formatter)
