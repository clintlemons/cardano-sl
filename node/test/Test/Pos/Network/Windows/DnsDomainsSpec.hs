{-# LANGUAGE CPP               #-}
{-# LANGUAGE OverloadedStrings #-}

#if !defined(mingw32_HOST_OS)
#define POSIX
#endif

{-# OPTIONS_GHC -Wno-unused-imports   #-}

-- | Specification of 'Pos.Network.Windows.DnsDomains'

module Test.Pos.Network.Windows.DnsDomainsSpec
       (
         spec
       ) where

import           Universum

import           Network.URI                    (isIPv4address)
import           Pos.Network.Types              (initDnsOnUse)
import           Test.Hspec                     (Expectation, Spec, describe, it,
                                                 shouldBe, shouldSatisfy)
import           Test.Hspec.QuickCheck          (prop)

#if !defined(POSIX)
import qualified Pos.Network.Windows.DnsDomains as Win
#endif

spec :: Spec
#if defined(POSIX)
spec = return ()
#else
spec = do
    describe "Default DNS server on Windows" $ do
        describe "getWindowsDefDnsServer" $ do
            prop "Successfully retrieves this Windows machine's DNS server"
                 prop_GetWindowsDefDnsServer
    describe "Multi-value lookups" $ do
        it "pool.ntp.org resolves correctly to more than 1 address" $ testLookupFor "pool.ntp.org"

testLookupFor :: ByteString -> Expectation
testLookupFor dnsDomain = do
    initDnsOnUse $ \resolve -> do
      res <- resolve dnsDomain
      (> 1) . length <$> res `shouldBe` Right True

prop_GetWindowsDefDnsServer :: Expectation
prop_GetWindowsDefDnsServer = do
    Win.getWindowsDefaultDnsServer >>= \dnsIpAddr ->
        dnsIpAddr `shouldSatisfy` (maybe False isIPv4address)
#endif
