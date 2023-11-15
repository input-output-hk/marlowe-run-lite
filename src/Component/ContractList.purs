module Component.ContractList where

import Prelude

import Cardano (AssetId)
import Cardano as Cardano
import CardanoMultiplatformLib (CborHex, bech32ToString)
import CardanoMultiplatformLib.Transaction (TransactionWitnessSetObject)
import Component.ApplyInputs as ApplyInputs
import Component.ApplyInputs.Machine (mkEnvironment)
import Component.ApplyInputs.Machine as ApplyInputs.Machine
import Component.ContractDetails as ContractDetails
import Component.ContractTemplates.ContractForDifferencesWithOracle as ContractForDifferencesWithOracle
import Component.ContractTemplates.Escrow as Escrow
import Component.ContractTemplates.Swap as Swap
import Component.CreateContract (runnerTag)
import Component.CreateContract as CreateContract
import Component.InputHelper (canInput)
import Component.Types (ContractInfo(..), ContractJsonString, MessageContent(..), MessageHub(..), MkComponentM, Page(..), WalletInfo)
import Component.Types.ContractInfo (MarloweInfo(..), SomeContractInfo(..))
import Component.Types.ContractInfo as ContractInfo
import Component.Widget.Table (orderingHeader) as Table
import Component.Widgets (buttonOutlinedInactive, buttonOutlinedPrimary, buttonOutlinedWithdraw)
import Component.Withdrawals as Withdrawals
import Contrib.Data.JSDate (toLocaleDateString, toLocaleTimeString) as JSDate
import Contrib.Fetch (FetchError)
import Contrib.Polyform.FormSpecBuilder (evalBuilder')
import Contrib.Polyform.FormSpecs.StatelessFormSpec (renderFormSpec)
import Contrib.React.Svg (loadingSpinnerLogo)
import Contrib.ReactBootstrap.DropdownButton (dropdownButton)
import Contrib.ReactBootstrap.DropdownItem (dropdownItem)
import Contrib.ReactBootstrap.FormSpecBuilders.StatelessFormSpecBuilders (StatelessBootstrapFormSpec, textInput)
import Control.Alt ((<|>))
import Control.Monad.Reader.Class (asks)
import Data.Argonaut (decodeJson, encodeJson, stringify)
import Data.Array (catMaybes, elem, filter, null, union)
import Data.Array as Array
import Data.Array.NonEmpty as NonEmptyArray
import Data.DateTime.Instant (Instant, instant, unInstant)
import Data.DateTime.Instant as Instant
import Data.Either (Either, hush)
import Data.Foldable (fold, for_, or)
import Data.FormURLEncoded.Query (FieldId(..), Query)
import Data.Function (on)
import Data.JSDate (fromDateTime) as JSDate
import Data.List (intercalate)
import Data.List as List
import Data.Map (Map, lookup)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Monoid as Monoid
import Data.Set as Set
import Data.String (contains, length)
import Data.String as String
import Data.String.Pattern (Pattern(..))
import Data.Time.Duration (Milliseconds(..), negateDuration)
import Data.Time.Duration as Duration
import Data.Tuple (snd)
import Data.Tuple.Nested (type (/\))
import Effect (Effect)
import Effect.Aff (Aff, delay, launchAff_)
import Effect.Class (liftEffect)
import Effect.Now as Now
import Foreign.Object as Object
import Language.Marlowe.Core.V1.Semantics.Types (Contract)
import Language.Marlowe.Core.V1.Semantics.Types as V1
import Marlowe.Runtime.Web.Client (put')
import Marlowe.Runtime.Web.Types (ContractHeader(ContractHeader), Payout(..), PutTransactionRequest(..), ServerURL, Tags(..), TransactionEndpoint, TransactionsEndpoint, TxOutRef, toTextEnvelope, txOutRefToString)
import Marlowe.Runtime.Web.Types as Runtime
import Polyform.Validator (liftFnM)
import Promise.Aff as Promise
import React.Basic (fragment)
import React.Basic.DOM (br, img, text) as DOOM
import React.Basic.DOM (text)
import React.Basic.DOM.Events (targetValue)
import React.Basic.DOM.Simplified.Generated as DOM
import React.Basic.DOM.Simplified.ToJSX (class ToJSX)
import React.Basic.Events (EventHandler, handler, handler_)
import React.Basic.Hooks (Hook, JSX, UseState, component, readRef, useEffectOnce, useState, useState', (/\))
import React.Basic.Hooks as React
import React.Basic.Hooks.Aff (useAff)
import React.Basic.Hooks.UseStatelessFormSpec (useStatelessFormSpec)
import ReactBootstrap (overlayTrigger, tooltip)
import ReactBootstrap.Icons (unsafeIcon)
import ReactBootstrap.Icons as Icons
import ReactBootstrap.Table (striped) as Table
import ReactBootstrap.Table (table)
import ReactBootstrap.Types (placement)
import ReactBootstrap.Types as OverlayTrigger
import Utils.React.Basic.Hooks (useMaybeValue, useStateRef')
import Wallet as Wallet
import WalletContext (WalletContext(..))
import Web.Clipboard (clipboard)
import Web.Clipboard as Clipboard
import Web.HTML (window)
import Web.HTML.Window (navigator)

type ContractId = TxOutRef

type ValidationError = String

data FormState
  = NotValidated
  | Failure ValidationError
  | Validated (Contract)

-- An example of a simple "custom hook"
useInput :: String -> Hook (UseState String) (String /\ EventHandler)
useInput initialValue = React.do
  value /\ setValue <- useState initialValue
  let onChange = handler targetValue (setValue <<< const <<< fromMaybe "")
  pure (value /\ onChange)

type SubmissionError = String

newtype NotSyncedYetInserts = NotSyncedYetInserts
  { add :: ContractInfo.ContractCreated -> Effect Unit
  , update :: ContractInfo.ContractUpdated -> Effect Unit
  }

type Props =
  { walletInfo :: WalletInfo Wallet.Api
  , walletContext :: WalletContext
  , possibleContracts :: Maybe (Array SomeContractInfo) -- `Maybe` indicates if the contracts where fetched already
  , contractMapInitialized :: Boolean
  , notSyncedYetInserts :: NotSyncedYetInserts
  , possibleInitialModalAction :: Maybe ModalAction
  , setPage :: Page -> Effect Unit
  , submittedWithdrawalsInfo :: Map ContractId (Array TxOutRef) /\ (ContractId -> TxOutRef -> Effect Unit)
  }

data OrderBy
  = OrderByCreationDate
  | OrderByLastUpdateDate

derive instance Eq OrderBy

submit :: CborHex TransactionWitnessSetObject -> ServerURL -> TransactionEndpoint -> Aff (Either FetchError Unit)
submit witnesses serverUrl transactionEndpoint = do
  let
    textEnvelope = toTextEnvelope witnesses ""

    req = PutTransactionRequest textEnvelope
  put' serverUrl transactionEndpoint req

data ContractTemplate = Escrow | Swap | ContractForDifferencesWithOracle

derive instance Eq ContractTemplate

data ModalAction
  = NewContract (Maybe ContractJsonString)
  | ContractDetails
      { contract :: Maybe V1.Contract
      , state :: Maybe V1.State
      , initialContract :: V1.Contract
      , initialState :: V1.State
      , transactionEndpoints :: Array Runtime.TransactionEndpoint
      , contractId :: Runtime.ContractId
      }
  | ApplyInputs ContractInfo TransactionsEndpoint ApplyInputs.Machine.MarloweContext
  | Withdrawal WalletContext (NonEmptyArray.NonEmptyArray String) TxOutRef (Array Payout)
  | ContractTemplate ContractTemplate

derive instance Eq ModalAction

queryFieldId :: FieldId
queryFieldId = FieldId "query"

mkForm :: (Maybe String -> Effect Unit) -> StatelessBootstrapFormSpec Effect Query { query :: Maybe String }
mkForm onFieldValueChange = evalBuilder' ado
  query <- textInput
    { validator: liftFnM \value -> do
        onFieldValueChange value -- :: Batteries.Validator Effect _ _  _
        pure value
    , name: Just queryFieldId
    , placeholder: "Filter contracts..."
    }
  in
    { query }

actionIconSizing :: String
actionIconSizing = " h4"

runnerTags :: Tags -> Array String
runnerTags (Tags metadata) = case Map.lookup runnerTag metadata >>= decodeJson >>> hush of
  Just arr ->
    Array.filter ((_ > 2) <<< length) -- ignoring short tags

      $ arr
  Nothing -> []

someContractTags :: SomeContractInfo -> Array String
someContractTags (SyncedConractInfo (ContractInfo { tags })) = runnerTags tags
someContractTags (NotSyncedUpdatedContract { contractInfo }) = do
  let
    ContractInfo { tags } = contractInfo
  runnerTags tags
someContractTags (NotSyncedCreatedContract { tags }) = runnerTags tags

mkContractList :: MkComponentM (Props -> JSX)
mkContractList = do
  MessageHub msgHubProps <- asks _.msgHub

  createContractComponent <- CreateContract.mkComponent
  applyInputsComponent <- ApplyInputs.mkComponent
  withdrawalsComponent <- Withdrawals.mkComponent
  contractDetails <- ContractDetails.mkComponent
  escrowComponent <- Escrow.mkComponent
  swapComponent <- Swap.mkComponent
  contractForDifferencesWithOracleComponent <- ContractForDifferencesWithOracle.mkComponent

  initialEnvironment <- liftEffect $ mkEnvironment

  liftEffect $ component "ContractList" \props@{ walletInfo, walletContext, possibleInitialModalAction, possibleContracts, contractMapInitialized, submittedWithdrawalsInfo } -> React.do
    let
      NotSyncedYetInserts notSyncedYetInserts = props.notSyncedYetInserts

    environment /\ setEnvironment <- useState' initialEnvironment

    possibleModalAction /\ setModalAction /\ resetModalAction <- React.do
      p /\ set /\ reset <- useMaybeValue possibleInitialModalAction
      let
        set' = case _ of
          action@(NewContract possibleJson) -> do
            props.setPage (CreateContractPage possibleJson)
            set action
          action -> do
            props.setPage OtherPage
            set action
        reset' = do
          props.setPage ContractListPage
          reset
      useEffectOnce do
        for_ possibleInitialModalAction set'
        pure $ pure unit
      pure (p /\ set' /\ reset')

    possibleModalActionRef <- useStateRef' possibleModalAction
    ordering /\ updateOrdering <- useState { orderBy: OrderByCreationDate, orderAsc: false }
    possibleQueryValue /\ setQueryValue <- useState' Nothing

    let
      form = mkForm setQueryValue
    { formState } <- useStatelessFormSpec
      { spec: form
      , onSubmit: const $ pure unit
      , validationDebounce: Duration.Seconds 0.5
      }
    let
      isContractComplete Nothing = true
      isContractComplete (Just V1.Close) = true
      isContractComplete _ = false

      possibleContracts' :: Maybe (Array SomeContractInfo)
      possibleContracts' = do
        contracts <- possibleContracts
        let
          sortedContracts = case ordering.orderBy of
            OrderByCreationDate -> Array.sortBy (compare `on` ContractInfo.createdAt) contracts
            OrderByLastUpdateDate -> Array.sortBy (compare `on` ContractInfo.updatedAt) contracts
        pure $
          if ordering.orderAsc then sortedContracts
          else Array.reverse sortedContracts

      possibleContracts'' = do
        let
          filtered = do
            queryValue <- possibleQueryValue
            contracts <- possibleContracts'
            pure $ contracts # Array.filter \someContract -> do
              let
                contractTags = ContractInfo.someContractTags someContract
                tagList = runnerTags (contractTags :: Tags)
                contractId = ContractInfo.someContractContractId someContract
                pattern = Pattern queryValue
              contains pattern (txOutRefToString contractId) || or (map (contains pattern) tagList)
        filtered <|> possibleContracts'
      nextTimeouts = fromMaybe [] do
        contracts <- possibleContracts''
        pure $ Array.sort $ catMaybes $ flip map contracts $ ContractInfo.someContractCurrentContract >=> case _ of
          V1.When _ timeout _ -> pure timeout
          _ -> Nothing

    -- Trigger auto refresh on timeouts so we can advance through the contract
    setCurrTimeout <- snd <$> useState' Nothing
    useAff nextTimeouts do
      now <- liftEffect Now.now
      for_ nextTimeouts \timeout -> do
        let
          nextTimeoutDelay = (unInstant timeout <> negateDuration (unInstant now))
        when (nextTimeoutDelay > Milliseconds 0.0) do
          delay (nextTimeoutDelay <> Milliseconds 1000.0)
          liftEffect $ mkEnvironment >>= setEnvironment
          liftEffect $ setCurrTimeout $ Just timeout

    pure $ DOM.div { className: "min-height-100vh position-relative z-index-1" } do
      let
        onError error = do
          msgHubProps.add $ Error $ DOOM.text $ fold [ "An error occured during contract submission: " <> error ]
          resetModalAction
      case possibleModalAction, submittedWithdrawalsInfo of
        Just (NewContract possibleInitialContract), _ -> createContractComponent
          { connectedWallet: walletInfo
          , walletContext
          , onDismiss: resetModalAction
          , onSuccess: \contractCreated -> do
              msgHubProps.add $ Success $ DOOM.text $ String.joinWith " "
                [ "Successfully created and submitted the contract."
                , "Contract transaction awaits to be included in the blockchain."
                ]
              resetModalAction
              notSyncedYetInserts.add contractCreated
          , onError
          , possibleInitialContract
          }
        Just (ApplyInputs contractInfo transactionsEndpoint marloweContext), _ -> do
          let
            onSuccess = \contractUpdated -> do
              msgHubProps.add $ Success $ DOOM.text $ fold
                [ "Successfully applied the inputs. Input application transaction awaits to be included in the blockchain." ]
              notSyncedYetInserts.update contractUpdated
              resetModalAction
          applyInputsComponent
            { transactionsEndpoint
            , contractInfo
            , marloweContext
            , onError
            , connectedWallet: walletInfo
            , onSuccess
            , onDismiss: resetModalAction
            }
        Just (Withdrawal _ roles contractId unclaimedPayouts), _ /\ updateSubmitted -> do
          let
            onSuccess = \_ -> do
              msgHubProps.add $ Success $ DOOM.text $ fold
                [ "Successfully withdrawed the funds. Withdrawal transaction awaits to be included in the blockchain." ]
              resetModalAction
          withdrawalsComponent
            { roles
            , connectedWallet: walletInfo
            , onSuccess
            , onError
            , onDismiss: resetModalAction
            , unclaimedPayouts
            , updateSubmitted: updateSubmitted contractId
            , walletContext
            }
        Just (ContractDetails { contractId, contract, state, initialContract, initialState, transactionEndpoints }), _ -> do
          let
            onClose = resetModalAction
          contractDetails { contractId, contract, onClose, state, transactionEndpoints, initialContract, initialState }

        -- This should be fixed later on - for now we put some stubs
        Just (ContractTemplate Escrow), _ -> escrowComponent
          { onSuccess: \_ -> resetModalAction
          , onDismiss: resetModalAction
          }

        Just (ContractTemplate Swap), _ -> swapComponent
          { onSuccess: \_ -> resetModalAction
          , onDismiss: resetModalAction
          }

        Just (ContractTemplate ContractForDifferencesWithOracle), _ -> contractForDifferencesWithOracleComponent
          { onSuccess: \_ -> resetModalAction
          , onDismiss: resetModalAction
          }

        Nothing, _ -> React.fragment
          [ DOM.div { className: "container" } $ DOM.div { className: "row" } do
              let
                disabled = false -- isNothing connectedWallet
                newContractButton = buttonOutlinedPrimary
                  { label: DOOM.text "Create a contract"
                  , onClick: do
                      readRef possibleModalActionRef >>= case _ of
                        Nothing -> setModalAction (NewContract Nothing)
                        _ -> pure unit
                  }
                templateContractButton = dropdownButton
                  { className: "d-none"
                  , title: fragment
                      [ Icons.toJSX $ unsafeIcon "file-earmark-medical h5 me-1"
                      , DOOM.text "Use Contract Template"
                      ]
                  -- , onToggle: const $ pure unit
                  }
                  [ dropdownItem
                      { onClick: handler_ $ setModalAction $ ContractTemplate Escrow
                      }
                      [ DOOM.text "Escrow" ]
                  , dropdownItem
                      { onClick: handler_ $ setModalAction $ ContractTemplate Swap
                      }
                      [ DOOM.text "Swap" ]
                  , dropdownItem
                      { onClick: handler_ $ setModalAction $ ContractTemplate ContractForDifferencesWithOracle
                      }
                      [ DOOM.text "Contract For Differences with Oracle" ]
                  ]
              [ DOM.div { className: "col-7 text-end" }
                  [ DOM.div { className: "form-group" } $ renderFormSpec form formState ]
              , DOM.div { className: "col-5" } $ Array.singleton $ do
                  let
                    buttons = DOM.div { className: "text-end" }
                      [ newContractButton
                      , templateContractButton
                      ]
                  if disabled then do
                    let
                      tooltipJSX = tooltip
                        { placement: placement.left }
                        (DOOM.text "Connect to a wallet to add a contract")
                    overlayTrigger
                      { overlay: tooltipJSX
                      , placement: OverlayTrigger.placement.bottom
                      }
                      -- Disabled button doesn't trigger the hook,
                      -- so we wrap it in a `span`
                      buttons
                  else
                    buttons
              ]
          , do
              let
                spinner =
                  DOM.div
                    { className: "col-12 position-relative d-flex justify-content-center align-items-center blur-bg z-index-sticky" }
                    $ loadingSpinnerLogo {}
                tableHeader =
                  DOM.thead {} do
                    let
                      orderingTh = Table.orderingHeader ordering updateOrdering "background-color-primary-light border-0 text-centered text-muted"
                      th content extraClassNames = DOM.th { className: "background-color-primary-light border-0 text-center " <> extraClassNames } [ content ]
                      thWithIcon src extraClassNames = th (DOOM.img { src }) extraClassNames
                      thWithLabel label extraClassNames = th (DOOM.text label) ("text-muted " <> extraClassNames)
                    [ DOM.tr {}
                        [ thWithIcon "/images/calendar_month.svg" "rounded-top"
                        , thWithIcon "/images/event_available.svg" ""
                        , thWithIcon "/images/fingerprint.svg" ""
                        , thWithIcon "/images/sell.svg" ""
                        , thWithIcon "/images/frame_65.svg" "rounded-top"
                        ]
                    , DOM.tr { className: "border-bottom-white border-bottom-4px" }
                        [ do
                            let
                              label = DOOM.text "Created"
                            orderingTh label OrderByCreationDate
                        , do
                            let
                              label = DOOM.text "Updated"
                            orderingTh label OrderByLastUpdateDate
                        , thWithLabel "Contract Id" "w-16rem"
                        , thWithLabel "Tags" ""
                        , thWithLabel "Actions" ""
                        ]
                    ]
                mkTable tbody = table { striped: Table.striped.boolean false, hover: true }
                  [ tableHeader
                  , tbody
                  ]

              DOM.div { className: "container" } $ DOM.div { className: "row" } $ DOM.div { className: "col-12" } $ DOM.div { className: "p-3 shadow-sm rounded my-3" } $ case possibleContracts'', contractMapInitialized of
                -- Pre search no started
                Nothing, _ -> fragment [ mkTable mempty, spinner ]
                -- Searching but nothing was found, still searching
                Just [], false -> fragment [ mkTable mempty, spinner ]
                -- Searching but nothing was found, search finished
                Just [], true -> fragment
                  [ mkTable mempty
                  , DOM.div { className: "container" }
                      $ DOM.div { className: "row" }
                      $ DOM.div { className: "col-12 text-center py-3 fw-bold" }
                      $
                        DOOM.text "No contracts found"
                  ]
                -- Searching and something was found
                Just contracts, _ -> DOM.div { className: "col-12 px-0" } do
                  let
                    tdCentered :: forall jsx. ToJSX jsx => jsx -> JSX
                    tdCentered = DOM.td { className: "text-center border-0" }
                    tdDateTime Nothing = tdCentered $ ([] :: Array JSX)
                    tdDateTime (Just dateTime) = tdCentered $ Array.singleton $ DOM.small {} do
                      let
                        jsDate = JSDate.fromDateTime dateTime
                      [ DOOM.text $ JSDate.toLocaleDateString jsDate
                      , DOOM.br {}
                      , DOOM.text $ JSDate.toLocaleTimeString jsDate
                      ]
                    tdInstant possibleInstant = do
                      let
                        possibleDateTime = Instant.toDateTime <$> possibleInstant
                      tdDateTime possibleDateTime

                    tdContractId contractId possibleMarloweInfo transactionEndpoints = do
                      let
                        conractIdStr = txOutRefToString contractId

                        copyToClipboard :: Effect Unit
                        copyToClipboard = window >>= navigator >>= clipboard >>= \c -> do
                          launchAff_ (Promise.toAffE $ Clipboard.writeText conractIdStr c)

                      tdCentered $ DOM.span { className: "d-flex" }
                        [ case possibleMarloweInfo of
                            Just (MarloweInfo { state, currentContract, initialContract, initialState }) -> do
                              DOM.a
                                do
                                  let
                                    onClick = setModalAction $ ContractDetails
                                      { contractId
                                      , contract: currentContract
                                      , state
                                      , initialState: initialState
                                      , initialContract: initialContract
                                      , transactionEndpoints
                                      }
                                  { className: "cursor-pointer text-decoration-none text-reset text-decoration-underline-hover truncate-text w-16rem d-inline-block"
                                  , onClick: handler_ onClick
                                  }
                                [ text conractIdStr ]
                            Nothing -> DOM.span { className: "text-muted truncate-text w-16rem" } $ text conractIdStr
                        , DOM.a
                            { href: "#"
                            , onClick: handler_ copyToClipboard
                            , className: "cursor-pointer text-decoration-none text-decoration-underline-hover text-reset"
                            }
                            $ Icons.toJSX
                            $ unsafeIcon "clipboard-plus ms-1 d-inline-block"
                        ]
                  mkTable
                    $ DOM.tbody {}
                    $ contracts <#> \someContract -> do
                        let
                          createdAt = ContractInfo.createdAt someContract
                          updatedAt = ContractInfo.updatedAt someContract
                          tags = runnerTags $ ContractInfo.someContractTags someContract
                          contractId = ContractInfo.someContractContractId someContract
                          possibleContract = ContractInfo.someContractCurrentContract someContract
                          isClosed = isContractComplete possibleContract
                          trClassName = "align-middle border-bottom-white border-bottom-4px" <> Monoid.guard isClosed " bg-secondary"
                          _data = Object.fromHomogeneous { testId: txOutRefToString contractId }
                        DOM.tr { className: trClassName, _data: _data } $ case someContract of
                          (SyncedConractInfo ci@(ContractInfo { _runtime, endpoints, marloweInfo })) -> do
                            let
                              ContractHeader { contractId } = _runtime.contractHeader
                            [ tdInstant createdAt
                            , tdInstant $ updatedAt <|> createdAt
                            , do
                                let
                                  transactionEndpoints = _runtime.transactions <#> \(_ /\ transactionEndpoint) -> transactionEndpoint
                                tdContractId contractId marloweInfo transactionEndpoints
                            , tdCentered [ DOOM.text $ intercalate ", " tags ]
                            , tdCentered do
                                let
                                  WalletContext { usedAddresses, balance: Cardano.Value balance } = walletContext
                                [ case endpoints.transactions, marloweInfo, submittedWithdrawalsInfo of
                                    Just transactionsEndpoint,
                                    Just (MarloweInfo { currencySymbol, initialContract, state: Just state, currentContract: Just contract }),
                                    _ -> do
                                      let
                                        rolesInContract = case currencySymbol of
                                          Just currencySymbol' -> listRoles $ filterCurrencySymbol currencySymbol' balance
                                          Nothing -> mempty
                                        parties = map V1.Role rolesInContract `union` map (V1.Address <<< bech32ToString) usedAddresses
                                      Monoid.guard
                                        (Array.any (canInput environment state contract) parties)
                                        buttonOutlinedPrimary
                                        { label: DOOM.text "Advance"
                                        -- , extraClassNames: "me-2"
                                        -- , extraClassNames: "font-weight-bold btn-outline-primary"
                                        , onClick: setModalAction $ ApplyInputs ci transactionsEndpoint { initialContract, state, contract }
                                        }
                                    _, Just (MarloweInfo { state: Nothing, currentContract: Nothing, currencySymbol: Nothing }), _ -> DOOM.text "Complete"
                                    _,
                                    Just (MarloweInfo { state: Nothing, currentContract: Nothing, currencySymbol: Just currencySymbol, unclaimedPayouts }),
                                    submittedPayouts /\ _ -> do
                                      let
                                        payouts = remainingPayouts contractId submittedPayouts unclaimedPayouts
                                        rolesConsidered = remainingRoles currencySymbol balance payouts
                                      Monoid.guard
                                        (null rolesConsidered)
                                        DOOM.text
                                        "Complete"
                                    _, _, _ -> buttonOutlinedInactive { label: DOOM.text "Syncing" }
                                , case marloweInfo, submittedWithdrawalsInfo of
                                    Just (MarloweInfo { currencySymbol: Just currencySymbol, state: _, unclaimedPayouts }), submittedPayouts /\ _ -> do
                                      let
                                        payouts = remainingPayouts contractId submittedPayouts unclaimedPayouts
                                        rolesConsidered = remainingRoles currencySymbol balance payouts

                                      case Array.uncons rolesConsidered of
                                        Just { head, tail } -> buttonOutlinedWithdraw
                                          { label: DOOM.text "Withdraw"
                                          -- , tooltipText: Just "This wallet has funds available for withdrawal from this contract. Click to submit a withdrawal"
                                          , onClick: setModalAction $ Withdrawal walletContext (NonEmptyArray.cons' head tail) contractId payouts
                                          }
                                        _ -> mempty
                                    _, _ -> mempty
                                ]
                            ]
                          NotSyncedCreatedContract {} -> do
                            [ tdInstant createdAt
                            , tdInstant $ updatedAt <|> createdAt
                            , tdContractId contractId Nothing []
                            , tdCentered [ DOOM.text $ intercalate ", " tags ]
                            , tdCentered [ buttonOutlinedInactive { label: DOOM.text "Syncing" } ]
                            ]
                          NotSyncedUpdatedContract { contractInfo } -> do
                            [ tdInstant createdAt
                            , tdInstant $ updatedAt <|> createdAt
                            , do
                                let
                                  ContractInfo { _runtime } = contractInfo
                                  transactionEndpoints = _runtime.transactions <#> \(_ /\ transactionEndpoint) -> transactionEndpoint
                                tdContractId contractId Nothing transactionEndpoints
                            , tdCentered [ DOOM.text $ intercalate ", " tags ]
                            , tdCentered [ buttonOutlinedInactive { label: DOOM.text "Syncing" } ]
                            ]
          ]

assetToString :: Cardano.AssetId -> Maybe String
assetToString Cardano.AdaAssetId = Nothing
assetToString (Cardano.AssetId _ assetName) = Cardano.assetNameToString assetName

prettyState :: V1.State -> String
prettyState = stringify <<< encodeJson

instantFromMillis :: Number -> Maybe Instant
instantFromMillis ms = instant (Duration.Milliseconds ms)

filterCurrencySymbol :: forall a. String -> Map AssetId a -> Map AssetId a
filterCurrencySymbol currencySymbol = Map.filterKeys $ \assetId -> Cardano.assetIdToString assetId `eq` currencySymbol

listRoles :: forall a. Map AssetId a -> Array String
listRoles = catMaybes <<< map assetToString <<< List.toUnfoldable <<< Set.toUnfoldable <<< Map.keys

remainingRoles :: forall a. String -> Map AssetId a -> Array Payout -> Array String
remainingRoles currencySymbol balance payouts = do
  let
    roles = listRoles $ filterCurrencySymbol currencySymbol balance
  Array.intersect roles $ map (\(Payout { role }) -> role) payouts

remainingPayouts :: ContractId -> Map ContractId (Array TxOutRef) -> Array Payout -> Array Payout
remainingPayouts contractId submittedPayouts unclaimedPayouts = do
  case lookup contractId submittedPayouts of
    Just s -> filter ((\(Payout { payoutId }) -> not (elem payoutId s))) unclaimedPayouts
    Nothing -> unclaimedPayouts

