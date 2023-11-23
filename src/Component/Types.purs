module Component.Types
  ( BrowserCapabilities(..)
  , ContractJsonString(..)
  , ConfigurationError(..)
  , MkContextBase(..)
  , MkComponentMBase(..)
  , MkComponentM
  , MessageHub(..)
  , Message(..)
  , MessageId(..)
  , MessageContent(..)
  , Page(..)
  , WalletInfo(..)
  , module Exports
  ) where

import Prelude

import CardanoMultiplatformLib as CardanoMultiplatformLib
import Component.Types.ContractInfo (ContractInfo(..)) as Exports
import Contrib.Cardano (Slotting)
import Control.Monad.Reader (ReaderT)
import Data.List (List)
import Data.Maybe (Maybe)
import Data.Newtype (class Newtype)
import Data.Tuple.Nested (type (/\))
import Effect (Effect)
import Marlowe.Runtime.Web (Runtime)
import Marlowe.Runtime.Web.Types (ServerURL)
import Marlowe.Runtime.Web.Types as Runtime
import React.Basic (JSX, ReactContext)
import Wallet as Wallet
import WalletContext (WalletContext)
import Web.Clipboard (Clipboard)

newtype WalletInfo wallet = WalletInfo
  { name :: String
  , icon :: String
  , isEnabled :: Boolean
  , apiVersion :: String
  , wallet :: wallet
  }

derive instance Newtype (WalletInfo wallet) _

data MessageContent
  = Info JSX
  | Success JSX
  | Warning JSX
  | Error JSX

type MessageId = Int

type Message =
  { id :: MessageId
  , msg :: MessageContent
  }

newtype MessageHub = MessageHub
  { add :: MessageContent -> Effect Unit
  , remove :: MessageId -> Effect Unit
  , ctx :: ReactContext (List Message)
  }

type BrowserCapabilities =
  { clipboard :: Maybe Clipboard
  }

type MkContextBase r =
  { browserCapabilities :: BrowserCapabilities
  , cardanoMultiplatformLib :: CardanoMultiplatformLib.Lib
  , walletInfoCtx :: ReactContext (Maybe (WalletInfo Wallet.Api /\ WalletContext))
  -- FIXME: use more advanced logger so we use levels and setup app verbosity.
  , logger :: String -> Effect Unit
  , runtime :: Runtime
  , msgHub :: MessageHub
  , slotting :: Slotting
  , develMode :: Boolean
  , networkId :: Runtime.NetworkId

  | r
  }

-- We use this monad during creation of the components.
-- This gives us ability to pass down "static" data.
-- which is not changing during the lifetime of the component.
-- `props` can change.
type MkComponentMBase r = ReaderT (MkContextBase r) Effect

type MkComponentM = MkComponentMBase ()

newtype ContractJsonString = ContractJsonString String

derive instance Eq ContractJsonString
derive instance Newtype ContractJsonString _

data Page
  = ContractListPage
  | LoginPage
  | CreateContractPage (Maybe ContractJsonString)
  | OtherPage

derive instance Eq Page

data ConfigurationError = RuntimeNotResponding ServerURL String
