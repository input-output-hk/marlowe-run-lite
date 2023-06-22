module Component.ContractList where

import Prelude

import CardanoMultiplatformLib (CborHex)
import CardanoMultiplatformLib.Transaction (TransactionWitnessSetObject)
import Component.ApplyInputs as ApplyInputs
import Component.BodyLayout as BodyLayout
import Component.ContractDetails as ContractDetails
import Component.CreateContract (runLiteTag)
import Component.CreateContract as CreateContract
import Component.InputHelper (rolesInContract)
import Component.Types (ContractInfo(..), MessageContent(..), MessageHub(..), MkComponentM, WalletInfo)
import Component.Types.ContractInfo (MarloweInfo(..))
import Component.Types.ContractInfo as ContractInfo
import Component.Widget.Table (orderingHeader) as Table
import Component.Widgets (buttonWithIcon, dropDownButtonWithIcon, linkWithIcon)
import Component.Withdrawals as Withdrawals
import Contrib.Fetch (FetchError)
import Contrib.React.Svg (loadingSpinnerLogo)
import Control.Alt ((<|>))
import Control.Monad.List.Trans (drop)
import Control.Monad.Reader.Class (asks)
import Data.Argonaut (encodeJson, stringify, toString)
import Data.Array as Array
import Data.Array.NonEmpty as NonEmptyArray
import Data.Either (Either)
import Data.Foldable (any, fold, foldMap, or)
import Data.FormURLEncoded.Query (FieldId(..), Query)
import Data.Function (on)
import Data.List (List(..), catMaybes, concat, filter, intercalate)
import Data.List as List
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, isNothing)
import Data.Newtype (un)
import Data.Set as Set
import Data.String (contains, length)
import Data.String.Pattern (Pattern(..))
import Data.Time.Duration (Seconds(..))
import Data.Tuple (snd)
import Data.Tuple.Nested (type (/\))
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Language.Marlowe.Core.V1.Semantics.Types (Contract)
import Language.Marlowe.Core.V1.Semantics.Types as V1
import Marlowe.Runtime.Web.Client (put')
import Marlowe.Runtime.Web.Types (ContractHeader(ContractHeader), Metadata(..), Payout(..), PutTransactionRequest(..), Runtime(..), ServerURL, Tags(..), TransactionEndpoint, TransactionsEndpoint, TxOutRef, WithdrawalsEndpoint, toTextEnvelope, txOutRefToString)
import Marlowe.Runtime.Web.Types as Runtime
import Polyform.Validator (liftFnM)
import React.Basic (fragment) as DOOM
import React.Basic.DOM (div_, text) as DOOM
import React.Basic.DOM (text)
import React.Basic.DOM.Events (targetValue)
import React.Basic.DOM.Simplified.Generated as DOM
import React.Basic.Events (EventHandler, handler, handler_)
import React.Basic.Hooks (Hook, JSX, UseState, component, readRef, useContext, useState, useState', (/\))
import React.Basic.Hooks as React
import React.Basic.Hooks.UseForm (useForm)
import React.Basic.Hooks.UseForm as UseForm
import ReactBootstrap (overlayTrigger, tooltip)
import ReactBootstrap.FormBuilder (BootstrapForm, textInput)
import ReactBootstrap.FormBuilder as FormBuilder
import ReactBootstrap.Icons (unsafeIcon)
import ReactBootstrap.Table (striped) as Table
import ReactBootstrap.Table (table)
import ReactBootstrap.Types (placement)
import ReactBootstrap.Types as OverlayTrigger
import Utils.React.Basic.Hooks (useMaybeValue', useStateRef')
import Wallet as Wallet
import WalletContext (WalletContext(..))
import Web.HTML.HTMLButtonElement (disabled)

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

type ContractListState = { modalAction :: Maybe ModalAction }

type Props =
  { possibleContracts :: Maybe (Array ContractInfo) -- `Maybe` indicates if the contracts where fetched already
  , connectedWallet :: Maybe (WalletInfo Wallet.Api)
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

data ModalAction
  = NewContract
  | ContractDetails V1.Contract V1.State
  | ApplyInputs TransactionsEndpoint V1.Contract V1.State
  | Withdrawal WithdrawalsEndpoint (NonEmptyArray.NonEmptyArray String) TxOutRef

derive instance Eq ModalAction

queryFieldId :: FieldId
queryFieldId = FieldId "query"

mkForm :: (Maybe String -> Effect Unit) -> BootstrapForm Effect Query { query :: Maybe String }
mkForm onFieldValueChange = FormBuilder.evalBuilder' ado
  query <- textInput
    { validator: liftFnM \value -> do
        onFieldValueChange value -- :: Batteries.Validator Effect _ _  _
        pure value
    , name: Just queryFieldId
    , placeholder: "Filter contracts..."
    , sizing: Just FormBuilder.FormControlLg
    }
  in
    { query }

actionIconSizing :: String
actionIconSizing = " h4"

mkContractList :: MkComponentM (Props -> JSX)
mkContractList = do
  MessageHub msgHubProps <- asks _.msgHub
  Runtime runtime <- asks _.runtime
  walletInfoCtx <- asks _.walletInfoCtx

  createContractComponent <- CreateContract.mkComponent
  applyInputsComponent <- ApplyInputs.mkComponent
  withdrawalsComponent <- Withdrawals.mkComponent
  contractDetails <- ContractDetails.mkComponent

  liftEffect $ component "ContractList" \{ connectedWallet, possibleContracts } -> React.do
    possibleWalletContext <- useContext walletInfoCtx <#> map (un WalletContext <<< snd)

    possibleModalAction /\ setModalAction /\ resetModalAction <- useMaybeValue'
    possibleModalActionRef <- useStateRef' possibleModalAction
    ordering /\ updateOrdering <- useState { orderBy: OrderByCreationDate, orderAsc: false }
    possibleQueryValue /\ setQueryValue <- useState' Nothing
    let
      form = mkForm setQueryValue
    { formState } <- useForm
      { spec: form
      , onSubmit: const $ pure unit
      , validationDebounce: Seconds 0.5
      }
    let
      possibleContracts' = do
        contracts <- possibleContracts
        let
          -- Quick and dirty hack to display just submited contracts as first
          someFutureBlockNumber = Runtime.BlockNumber 9058430
          sortedContracts = case ordering.orderBy of
            OrderByCreationDate -> Array.sortBy (compare `on` (fromMaybe someFutureBlockNumber <<< map (_.blockNo <<< un Runtime.BlockHeader) <<< ContractInfo.createdAt)) contracts
            OrderByLastUpdateDate -> Array.sortBy (compare `on` (fromMaybe someFutureBlockNumber <<< map (_.blockNo <<< un Runtime.BlockHeader) <<< ContractInfo.updatedAt)) contracts
        pure $
          if ordering.orderAsc then sortedContracts
          else Array.reverse sortedContracts
      possibleContracts'' = do
        let
          filtered = do
            queryValue <- possibleQueryValue
            contracts <- possibleContracts'
            pure $ contracts # Array.filter \(ContractInfo { contractId, tags: Tags metadata }) -> do
              let
                tagList = case Map.lookup runLiteTag metadata of
                  Just (Metadata tag) ->
                    filter ((_ > 2) <<< length) -- ignoring short tags

                      $ catMaybes
                      $ map toString
                      $ Map.values tag
                  Nothing -> Nil
                pattern = Pattern queryValue
              contains pattern (txOutRefToString contractId) || or (map (contains pattern) tagList)
        filtered <|> possibleContracts'

      --         pure $ if ordering.orderAsc
      --           then sortedContracts
      --           else Array.reverse sortedContracts

      isLoadingContracts :: Boolean
      isLoadingContracts = case possibleContracts'' of
        Nothing -> true
        Just contracts -> any (\(ContractInfo { marloweInfo }) -> isNothing marloweInfo) contracts

    pure $
      case possibleModalAction, connectedWallet of
        Just NewContract, Just cw -> createContractComponent
          { connectedWallet: cw
          , onDismiss: resetModalAction
          , onSuccess: \_ -> do
              msgHubProps.add $ Success $ DOOM.text $ fold
                [ "Successfully created and submitted the contract. Contract transaction awaits to be included in the blockchain."
                , "Contract status should change to 'Confirmed' at that point."
                ]
              resetModalAction
          }
        Just (ApplyInputs transactionsEndpoint contract st), Just cw -> do
          let
            onSuccess = \_ -> do
              msgHubProps.add $ Success $ DOOM.text $ fold
                [ "Successfully applied the inputs. Input application transaction awaits to be included in the blockchain." ]
              resetModalAction
          applyInputsComponent
            { inModal: true
            , transactionsEndpoint
            , contract
            , state: st
            , connectedWallet: cw
            , onSuccess
            , onDismiss: resetModalAction
            }
        Just (Withdrawal withdrawalsEndpoint roles contractId), Just cw -> do
          let
            onSuccess = \_ -> do
              msgHubProps.add $ Success $ DOOM.text $ fold
                [ "Successfully applied the inputs. Input application transaction awaits to be included in the blockchain." ]
              resetModalAction
          withdrawalsComponent
            { inModal: true
            , withdrawalsEndpoint
            , roles
            , contractId
            , connectedWallet: cw
            , onSuccess
            , onDismiss: resetModalAction
            }
        Just (ContractDetails contract state), _ -> do
          let
            onClose = resetModalAction
          contractDetails { contract, onClose, state }

        Nothing, _ -> BodyLayout.component
          { title: "Your Marlowe Contracts"
          , description: DOOM.div_
              [ DOM.div { className: "pb-3" } $ DOM.p { className: "white-color h5" } $ DOOM.text "To the right, you will find a list of all contracts that your wallet is involved in on the Cardano Blockchain's `preview` network."
              , DOM.div { className: "pb-3" } $ DOM.p { className: "white-color h5" } $ DOOM.text "Your involvement means that one of your wallet addresses is a part of the contract (some contracts are non fully public) or that you have a token (so called \"role token\") which gives you permission to act as a party in some contract."
              -- , DOM.div "You can filter the list by contract ID or by contract creator. You can also click on a contract id to view its details."
              , DOM.div { className: "pb-3" } $ DOM.p { className: "white-color h5" } $ DOOM.text "Click on the 'New Contract' button to upload a new contract or try out one of our contract templates."
              ]
          , content: React.fragment
              [ if isLoadingContracts then
                  DOM.div
                    { className: "col-12 position-absolute top-0 start-0 w-100 h-100 d-flex justify-content-center align-items-center blur-bg"
                    }
                    $ loadingSpinnerLogo
                        {}
                else
                  mempty
              , DOM.div { className: "row" } do
                  let
                    disabled = isNothing connectedWallet
                    newContractButton = buttonWithIcon
                      { icon: unsafeIcon "file-earmark-plus h5 mr-2"
                      , label: DOOM.text "New Contract"
                      , extraClassNames: "font-weight-bold"
                      , disabled
                      , onClick: do
                          readRef possibleModalActionRef >>= case _ of
                            Nothing -> setModalAction NewContract
                            _ -> pure unit
                      }
                    templateContractButton = dropDownButtonWithIcon
                      { id: "templateContractMenuButton"
                      , icon: unsafeIcon "file-earmark-plus h5 mr-2"
                      , label: DOOM.text "Use Template"
                      , disabled
                      , extraClassNames: "font-weight-bold"
                      , dropDownMenuItems:
                          [ { menuLabel: "Escrow"
                            , onClick: do
                                possibleModalAction <- readRef possibleModalActionRef
                                case possibleModalAction of
                                  Nothing -> setModalAction NewContract
                                  _ -> pure unit
                            }
                          , { menuLabel: "Swap"
                            , onClick: do
                                possibleModalAction <- readRef possibleModalActionRef
                                case possibleModalAction of
                                  Nothing -> setModalAction NewContract
                                  _ -> pure unit
                            }
                          ]
                      }
                    fields = UseForm.renderForm form formState
                    body = DOM.div { className: "form-group" } fields
                    spacing = "m-4"
                  [ DOM.div { className: "col-7 text-end" } $ DOM.div { className: spacing }
                      [ body
                      -- , actions
                      ]
                  , DOM.div { className: "col-5" } $ Array.singleton $
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
                          (DOM.div { className: spacing } [ newContractButton ])
                      else
                        DOM.div { className: "row my-4 justify-content-end" }
                          [ DOM.div { className: "col-3" } [ newContractButton ]
                          , DOM.div
                              { className: "col-3" }
                              [ templateContractButton ]
                          ]
                  ]
              , case possibleContracts'' of
                  Nothing -> mempty
                  Just contracts -> DOM.div { className: "row" } $ DOM.div { className: "col-12 mt-3" } do

                    [ table { striped: Table.striped.boolean true, hover: true }
                        [ DOM.thead {} do
                            let
                              orderingTh = Table.orderingHeader ordering updateOrdering
                              th label = DOM.th { className: "text-center text-muted" } [ label ]
                            [ DOM.tr {}
                                [ do
                                    let
                                      label = DOOM.fragment [ DOOM.text "Created" ] --, DOOM.br {},  DOOM.text "(Block number)"]
                                    orderingTh label OrderByCreationDate
                                , DOM.th { className: "text-center w-16rem" } $ DOOM.text "Contract Id"
                                , th $ DOOM.text "Tags"
                                , th $ DOOM.text "Actions"
                                ]
                            ]
                        , DOM.tbody {} $ contracts <#> \ci@(ContractInfo { _runtime, endpoints, marloweInfo, tags: Tags metadata }) ->
                            let
                              ContractHeader { contractId, status } = _runtime.contractHeader
                              tdCentered = DOM.td { className: "text-center" }
                            in
                              DOM.tr { className: "align-middle" }
                                [ tdCentered [ text $ foldMap show $ map (un Runtime.BlockNumber <<< _.blockNo <<< un Runtime.BlockHeader) $ ContractInfo.createdAt ci ]
                                , tdCentered
                                    [ DOM.a
                                        do
                                          let
                                            onClick = case marloweInfo of
                                              Just (MarloweInfo { state: Just currentState, currentContract: Just currentContract }) -> do
                                                setModalAction $ ContractDetails currentContract currentState
                                              _ -> pure unit
                                            disabled = isNothing marloweInfo
                                          { className: "btn btn-link text-decoration-none text-reset text-decoration-underline-hover truncate-text w-16rem"
                                          , onClick: handler_ onClick
                                          -- , disabled
                                          }
                                        [ text $ txOutRefToString contractId ]
                                    ]
                                , tdCentered
                                    [ case Map.lookup runLiteTag metadata of
                                        Just (Metadata tag) ->
                                          let
                                            values = catMaybes $ map toString $ Map.values tag
                                          in
                                            DOOM.text $ intercalate ", " values
                                        Nothing -> mempty
                                    ]
                                , tdCentered
                                    [ do
                                        case endpoints.transactions, marloweInfo of
                                          Just transactionsEndpoint, Just (MarloweInfo { state: Just currentState, currentContract: Just currentContract }) -> linkWithIcon
                                            { icon: unsafeIcon $ "fast-forward-fill" <> actionIconSizing
                                            , label: mempty
                                            , tooltipText: Just "Apply available inputs to the contract"
                                            , tooltipPlacement: Just placement.left
                                            , onClick: setModalAction $ ApplyInputs transactionsEndpoint currentContract currentState
                                            }
                                          _, Just (MarloweInfo { state: Nothing, currentContract: Nothing }) -> linkWithIcon
                                            { icon: unsafeIcon $ "file-earmark-check-fill success-color" <> actionIconSizing
                                            , tooltipText: Just "Contract is completed - click on contract id to see in Marlowe Explorer"
                                            , tooltipPlacement: Just placement.left
                                            , label: mempty
                                            , onClick: mempty
                                            }
                                          _, _ -> mempty
                                    , case marloweInfo, possibleWalletContext of
                                        Just (MarloweInfo { initialContract, state: _ , unclaimedPayouts }), Just { balance } -> do
                                          let
                                            rolesFromContract = rolesInContract initialContract
                                            roleTokens = List.toUnfoldable <<< concat <<< map Set.toUnfoldable <<< map Map.keys <<< Map.values $ balance
                                          case Array.uncons (Array.intersect (Array.intersect roleTokens rolesFromContract) (map (\(Payout { role }) -> role) unclaimedPayouts)) of
                                            Just { head, tail } ->
                                              linkWithIcon
                                                { icon: unsafeIcon $ "cash-coin warning-color" <> actionIconSizing
                                                , label: mempty
                                                , tooltipText: Just "This wallet has funds available for withdrawal from this contract. Click to submit a withdrawal"
                                                , onClick: setModalAction $ Withdrawal runtime.withdrawalsEndpoint (NonEmptyArray.cons' head tail) contractId
                                                }
                                            _ -> mempty
                                        _, _ -> mempty
                                    ]
                                ]
                        ]
                    ]
              ]
          }
        _, _ -> mempty

prettyState :: V1.State -> String
prettyState = stringify <<< encodeJson
