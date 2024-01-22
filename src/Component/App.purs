module Component.App where

import Prelude

import Cardano as C
import CardanoMultiplatformLib (bech32ToString)
import Component.Assets.Svgs (marloweLogoUrl)
import Component.ConnectWallet (mkConnectWallet, walletInfo)
import Component.ContractList (ModalAction(..), NotSyncedYetInserts(..), mkContractList)
import Component.CreateContract (runnerCreatorTag)
import Component.Footer (footer)
import Component.LandingPage (mkLandingPage)
import Component.MessageHub (mkMessageBox, mkMessagePreview)
import Component.Testing (mkDataTestAttrs)
import Component.Types (ConfigurationError(..), ContractInfo(..), ContractJsonString, MessageHub(MessageHub), MkComponentMBase, Page(..), WalletInfo(..))
import Component.Types as MessageHub
import Component.Types.ContractInfo (ContractCreated(..), ContractUpdated(..)) as ContractInfo
import Component.Types.ContractInfo (SomeContractInfo)
import Component.Types.ContractInfoMap as ContractInfoMap
import Component.Widgets (linkWithIcon)
import Contrib.React.Svg (svgImg)
import Control.Monad.Error.Class (catchError)
import Control.Monad.Loops (untilJust)
import Control.Monad.Reader.Class (asks)
import Data.Array ((..))
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.List as List
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), isJust, isNothing)
import Data.Monoid as Monoid
import Data.Newtype (un)
import Data.Newtype as Newtype
import Data.String (joinWith) as String
import Data.String.Extra (upperCaseFirst) as String
import Data.Time.Duration (Milliseconds(..))
import Data.Traversable (for, traverse)
import Data.Tuple.Nested (type (/\), (/\))
import Effect (Effect)
import Effect.Aff (Aff, delay, forkAff, launchAff_, supervise)
import Effect.Class (liftEffect)
import Effect.Exception (throw)
import Foreign.Internal.Stringify (unsafeStringify)
import Marlowe.Runtime.Web.Streaming (ContractWithTransactionsStream(..), PollingInterval(..), RequestInterval(..))
import Marlowe.Runtime.Web.Streaming as Streaming
import Marlowe.Runtime.Web.Types (Runtime(..), ContractsQueryParams)
import Marlowe.Runtime.Web.Types as Runtime
import React.Basic (JSX, fragment)
import React.Basic as ReactContext
import React.Basic.DOM (img, text) as DOOM
import React.Basic.DOM.Simplified.Generated (a, div, li, span, ul) as DOM
import React.Basic.Events (handler_)
import React.Basic.Events (handler_) as DOM
import React.Basic.Hooks (component, provider, readRef, useEffect, useState, useState')
import React.Basic.Hooks as React
import React.Basic.Hooks.Aff (useAff)
import ReactBootstrap.Icons (unsafeIcon)
import ReactBootstrap.Modal (modal, modalBody, modalHeader)
import ReactBootstrap.Offcanvas (offcanvas)
import ReactBootstrap.Offcanvas as Offcanvas
import Record as Record
import Runner.Contrib.Effect.Aff (withTimeout)
import Type.Prelude (Proxy(..))
import Utils.React.Basic.Hooks (useLoopAff, useStateRef, useStateRef')
import Wallet as Wallet
import WalletContext (WalletContext(..))
import WalletContext as WalletContext
import Web.HTML (window)

-- | Debugging helpers which allow us to automatically connect wallet
data WalletBrand
  = Eternl
  | Gero
  | Lace
  | Nami
  | Typhon
  | Yoroi

instance Show WalletBrand where
  show Eternl = "Eternl"
  show Gero = "Gero"
  show Lace = "Lace"
  show Nami = "Nami"
  show Typhon = "Typhon"
  show Yoroi = "Yoroi"

autoConnectWallet :: WalletBrand -> (WalletInfo Wallet.Api -> Effect Unit) -> Aff Unit
autoConnectWallet walletBrand onSuccess = liftEffect (window >>= Wallet.cardano) >>= case _ of
  Nothing -> do
    -- We use this function in development mode, so we can just throw an error
    liftEffect $ throw $ "Missing \"cardano\" window attr"
  Just cardano -> do
    let
      extractWallet = case walletBrand of
        Eternl -> Wallet.eternl
        Gero -> Wallet.gerowallet
        Lace -> Wallet.lace
        Nami -> Wallet.nami
        Typhon -> Wallet.typhon
        Yoroi -> Wallet.yoroi
    liftEffect (extractWallet cardano) >>= traverse walletInfo >>= join >>> case _ of
      Nothing -> do
        liftEffect $ throw $ "Unable to extract wallet " <> show walletBrand
      Just walletInfo@(WalletInfo { wallet }) -> do
        Wallet.enable wallet >>= case _ of
          Right walletApi -> do
            let
              walletInfo' = Newtype.over WalletInfo (Record.set (Proxy :: Proxy "wallet") walletApi) walletInfo
            liftEffect $ onSuccess walletInfo'
          -- FIXME: paluh - handle error
          Left _ -> pure unit

-- | Use this switch to autoconnect the wallet for testing.
debugWallet :: Maybe WalletBrand
debugWallet = Nothing -- | Just Nami -- Just Lace -- Nami -- Eternl -- Nami -- Nothing

data DisplayOption = Default | About

derive instance Eq DisplayOption

type ContractInfoMap = Map Runtime.ContractId SomeContractInfo

type Props =
  { possibleInitialContract :: Maybe ContractJsonString
  , setPage :: Page -> Effect Unit
  , possibleConfigurationError :: Maybe ConfigurationError
  }

walletContextToParams :: WalletContext -> ContractsQueryParams /\ ContractsQueryParams
walletContextToParams (WalletContext walletCtx) = do
  let
    changeAddress = walletCtx.changeAddress

    tokens = do
      let
        C.Value valueMap = walletCtx.balance
      Array.filter (not <<< eq C.AdaAssetId) $ Array.fromFoldable $ Map.keys valueMap

    partyParams = { partyAddresses: walletCtx.usedAddresses, partyRoles: tokens, tags: [] }
    -- This is a partial workaround to the current limitation of the Runtime. Runtime currently
    -- ignores the creator address (which is part of the state) when we query for contracts by
    -- party.
    -- In order to be able to discover contracts created by the current wallet, we tag the contracts
    -- by the creator address (overlaps are not problematic).
    tagsParams = { partyAddresses: [], partyRoles: [], tags: [ runnerCreatorTag changeAddress ] }
  partyParams /\ tagsParams

mkApp :: MkComponentMBase () (Props -> JSX)
mkApp = do
  landingPage <- mkLandingPage
  messageBox <- liftEffect $ mkMessageBox
  messagePreview <- liftEffect $ mkMessagePreview
  -- modal <- liftEffect $ mkModal
  logger <- asks _.logger
  cardanoMultiplatformLib <- asks _.cardanoMultiplatformLib
  subcomponents <- do
    contractListComponent <- mkContractList
    -- eventListComponent <- mkEventList
    connectWallet <- mkConnectWallet
    pure { contractListComponent, connectWallet, messageBox }

  walletInfoCtx <- asks _.walletInfoCtx
  msgHub@(MessageHub msgHubProps) <- asks _.msgHub
  slotting <- asks _.slotting

  Runtime runtime <- asks _.runtime

  liftEffect $ component "App" \props -> React.do
    possibleWalletInfo /\ setWalletInfo <- useState' $ Nothing
    let
      walletInfoName = _.name <<< un WalletInfo <$> possibleWalletInfo

    possibleWalletInfoRef <- useStateRef walletInfoName possibleWalletInfo
    possibleWalletContext /\ setWalletContext <- useState' Nothing
    possibleWalletContextRef <- useStateRef' possibleWalletContext

    (possibleSyncFn /\ setSyncFn) <- useState' Nothing

    -- FIXME: track withdrawal status in similar fashion to contract info
    submittedWithdrawalsInfo <- React.do
      submit /\ updateSubmit <- useState (Map.empty :: Map Runtime.ContractId (Array Runtime.TxOutRef))
      let
        addAndSync contractId payoutId = do
          updateSubmit $ Map.insertWith append contractId [ payoutId ]
      pure (submit /\ addAndSync)

    (contractInfoMap /\ contractMapInitialized) /\ updateContractInfoMap <- useState (ContractInfoMap.uninitialized slotting /\ false)

    let
      notSyncedYetInserts = NotSyncedYetInserts do
        let
          -- FIXME: Make this loop a bit smarter and after some time stop trying and notify
          -- the user that we give up.
          resyncLoop contractId =
            for_ possibleSyncFn \sync ->
              for_ (1 .. 30) \_ -> do
                delay (Milliseconds 5000.0)
                sync contractId `catchError` \err -> do
                  liftEffect $ logger $ unsafeStringify err
                  pure unit

          add :: ContractInfo.ContractCreated -> Effect Unit
          add cc@(ContractInfo.ContractCreated { contractId }) = do
            launchAff_ $ resyncLoop contractId
            updateContractInfoMap $ \(contractMap /\ initialized) ->
              ContractInfoMap.insertContractCreated cc contractMap /\ initialized

          update :: ContractInfo.ContractUpdated -> Effect Unit
          update cu@(ContractInfo.ContractUpdated { contractInfo: ContractInfo { contractId } }) = do
            launchAff_ $ resyncLoop contractId
            updateContractInfoMap $ \(contractMap /\ initialized) ->
              ContractInfoMap.insertContractUpdated cu contractMap /\ initialized
        { add, update }

      possibleChangeAddress = (_.changeAddress <<< un WalletContext) <$> possibleWalletContext
      possibleParams = walletContextToParams <$> possibleWalletContext

    -- Whenever we get a new token in the wallet or new address we update the query params
    -- which are used to filter the contracts in the streaming thread.
    updateStreamingQueryParamsRef <- React.useRef (const $ pure unit)
    useEffect possibleParams do
      for_ possibleParams \(partyParams /\ tagParams) -> do
        updateQueryParams <- React.readRef updateStreamingQueryParamsRef
        updateQueryParams [ partyParams, tagParams ]
      pure $ pure unit

    useAff possibleChangeAddress $ case possibleParams of
      Just (partyParams /\ tagParams) | partyParams.partyAddresses /= [] || partyParams.partyRoles /= [] || tagParams.tags /= [] -> do
        let
          reqInterval = RequestInterval (Milliseconds 50.0)
          pollInterval = PollingInterval (Milliseconds 60_000.0)
          params = [ partyParams, tagParams ]

        ContractWithTransactionsStream contractStream <- Streaming.mkContractsWithTransactions
          pollInterval
          reqInterval
          params
          (const true)
          Nothing
          runtime.serverURL

        liftEffect $ React.writeRef updateStreamingQueryParamsRef $ contractStream.updateQueryParams
        let
          syncDelay = Milliseconds 1_000.0

        supervise do
          void $ forkAff do
            _ <- contractStream.getState
            -- An ugly hack to set initialize map only after the sync
            delay syncDelay
            delay syncDelay
            liftEffect $ updateContractInfoMap \(contractMap /\ _) -> (contractMap /\ true)

          void $ forkAff do
            untilJust do
              newSynced <- liftEffect $ contractStream.getLiveState
              liftEffect $ updateContractInfoMap \(contractMap /\ initialized) ->
                ContractInfoMap.updateSynced newSynced contractMap /\ initialized
              delay syncDelay
              pure Nothing

          liftEffect $ setSyncFn (Just contractStream.sync)
          contractStream.start
      _ -> do
        liftEffect $ React.writeRef updateStreamingQueryParamsRef (const $ pure unit)
        let
          initialized = isJust possibleWalletContext
        liftEffect $ updateContractInfoMap (const (ContractInfoMap.uninitialized slotting /\ initialized))

    useLoopAff walletInfoName (Milliseconds 20_000.0) do
      pwi <- liftEffect $ readRef possibleWalletInfoRef
      pwc <- liftEffect $ readRef possibleWalletContextRef
      case pwi, pwc of
        Nothing, Nothing -> pure unit
        Nothing, Just _ -> do
          liftEffect $ setWalletContext Nothing
        Just (WalletInfo walletInfo), Nothing -> do
          -- This only checks if the internal effect finished successfully
          (res :: Maybe Unit) <- withTimeout (Milliseconds 10000.0) do
            walletContext <- WalletContext.walletContext cardanoMultiplatformLib walletInfo.wallet
            liftEffect $ setWalletContext walletContext
            -- FIXME: Another work around the rounting issue.
            when (isNothing pwc) do
              liftEffect $ props.setPage ContractListPage
          case res of
            Nothing -> liftEffect do
              msgHubProps.add $ MessageHub.Error $ DOOM.text "Wallet is not responding. Please check its configuration or try another wallet"
              setWalletInfo Nothing
            Just _ -> pure unit
        _, _ -> pure unit

    disconnectingWallet /\ setDisconnectingWallet <- useState' false
    checkingNotifications /\ setCheckingNotifications <- useState' false

    -- TODO: re-introduce notifications
    -- On the app level we keep the previous wallet context
    -- so we can reuse pieces of contract info from the previous
    -- state in a safe manner.
    -- newtype AppContractInfoMap = AppContractInfoMap
    --   { walletContext :: Maybe WalletContext
    --   , map :: ContractInfoMap
    --   }
    -- We are ignoring contract events for now and we update the whole contractInfo set.
    --    upstreamVersion <- useEmitter' initialVersion (Subscription.bindEffect (const now) emitter)
    --    upstreamVersionRef <- useStateRef' upstreamVersion
    --
    --    -- Let's use versioning so we avoid large comparison.
    --    (version /\ contractMap) /\ setContractMap <- useState' (upstreamVersion /\ AppContractInfoMap { walletContext: possibleWalletContext, map: Map.empty })
    --    idRef <- useStateRef version contractMap
    --
    --    useEffect (upstreamVersion /\ possibleWalletContext) do
    --      updates <- contractStream.getLiveState
    --      old <- readRef idRef
    --      newVersion <- readRef upstreamVersionRef
    --      let
    --        new = updateAppContractInfoMap old possibleWalletContext updates
    --        _map (AppContractInfoMap { map }) = map
    --
    --        old' = _map old
    --        new' = _map new
    --
    --        (additionsNumber :: Int) = length $ Map.additions (Map.Old old') (Map.New new')
    --        (deletionsNumber :: Int) = length $ Map.deletions (Map.Old old') (Map.New new')
    --
    --      when (deletionsNumber > 0 || additionsNumber > 0) do
    --        msgHubProps.add $ Info $ DOOM.text $
    --          "Update: "
    --            <> (if deletionsNumber == 0 then "" else show deletionsNumber <> " contracts removed")
    --            <> (if deletionsNumber > 0 && additionsNumber > 0 then ", " else "")
    --            <> (if additionsNumber == 0 then "" else show additionsNumber <> " contracts discovered")
    --            <> "."
    --
    --
    --      setContractMap (newVersion /\ new)
    --      pure $ pure unit

    -- -- This causes a lot of re renders - we avoid it for now by
    -- -- enforcing manual offcanvas toggling.
    -- -- FIXME: expose the msgs emitter and use it to detect
    -- -- when message box is empty.
    -- msgs <- useContext msgHubProps.ctx
    -- useEffect (List.null msgs) do
    --   when (List.null msgs) do
    --     setCheckingNotifications false
    --   pure $ pure unit

    useAff unit $ for debugWallet \walletBrand ->
      autoConnectWallet walletBrand \walletInfo -> do
        liftEffect $ setWalletInfo $ Just walletInfo

    let
      appError = case props.possibleConfigurationError of
        Just (RuntimeNotResponding _ _) -> modal
          { -- onHide: onDismiss -- : setConfiguringWallet false
            -- , footer: formActions
            -- , body: formBody
            -- , title: DOOM.text "Connect wallet"
            show: true
          }
          [ modalHeader {} $ DOOM.text "App configuration error"
          , modalBody {}
              [ DOM.div { className: "container" } $ DOM.div { className: "row" } $ DOM.div { className: "col-12" }
                  $ DOM.div { className: "alert alert-danger" }
                  $ DOOM.text
                  $ String.joinWith " "
                      [ "It seems that there is a connection problem with the backend and we are not able to initilize the app."
                      , "Please try again later by refreshing the page or contact support."
                      ]
              ]
          -- , modalFooter {} formActions
          ]
        Nothing -> mempty
      possibleContracts = Array.fromFoldable <$> ContractInfoMap.getContractsMap contractInfoMap
      topNavbar = provider walletInfoCtx ((/\) <$> possibleWalletInfo <*> possibleWalletContext) $
        [ DOM.div { className: "container" }
            [ DOM.div { className: "row" }
                [ DOM.div
                    { className: "col-3 pt-2 pb-4 background-color-primary-light", id: "marlowe-logo-container" } $
                    DOM.a { href: "#" } [ svgImg { src: marloweLogoUrl } ]
                , DOM.div { className: "col-9 pt-3 bg-white" } $ DOM.ul { className: "list-unstyled d-flex justify-content-end align-items-center" } $
                    [ DOM.li {} $ ReactContext.consumer msgHubProps.ctx \msgs ->
                        [ linkWithIcon
                            { icon: unsafeIcon "h5"
                            , label: mempty
                            , extraClassNames: "nav-link"
                            , tooltipText: Just $ if List.null msgs then "No new notifications" else "You have new notifications"
                            , onClick: setCheckingNotifications true
                            , disabled: List.null msgs
                            }
                        ]
                    ] <> Monoid.guard (isJust possibleWalletInfo) do
                      [ DOM.li {} $
                          case possibleWalletInfo, possibleWalletContext of
                            Just (WalletInfo wallet), Just (WalletContext ctx) -> do
                              let
                                onMouseOver = DOM.handler_ $ setDisconnectingWallet true
                                onMouseLeave = DOM.handler_ $ setDisconnectingWallet false
                                disconnect = do
                                  setWalletInfo Nothing
                                  setWalletContext Nothing
                                  setDisconnectingWallet false
                                  props.setPage LoginPage
                                address' = bech32ToString $ ctx.changeAddress
                              DOM.div
                                { _data: mkDataTestAttrs "wallet-info" { "wallet-address": address' }
                                , className: "position-relative"
                                , onMouseOver
                                , onMouseLeave
                                } $
                                [ -- DOM.
                                  --   { className: "btn btn-link text-decoration-none text-reset text-decoration-underline-hover nav-link"
                                  --- , onClick: handler preventDefault (const $ onClick)
                                  DOM.div { className: "h7 d-flex align-items-center mb-0 pb-3" }
                                    [ DOOM.img { src: wallet.icon, alt: String.upperCaseFirst wallet.name, className: "w-1_2rem me-1" }
                                    , DOM.span { className: "cursor-pointer fw-normal truncate-text text-color-gray w-10rem d-inline-block fw-bold" }
                                        [ DOOM.text address' ]
                                    ]
                                ] <> Monoid.guard disconnectingWallet do
                                  pure $ DOM.div
                                    { onClick: handler_ disconnect
                                    , className: "cursor-pointer rounded position-absolute top-1_7rem px-3 py-2 right-0 text-center bg-white bg-secondary-hover shadow-sm w-max-content"
                                    }
                                    [ DOOM.text "Disconnect Wallet"
                                    , DOOM.img { src: "/images/disconnect.svg", className: "ms-1" }
                                    ]
                            _, _ -> mempty
                      ]
                ]
            ]
        ]
    pure $ case possibleWalletInfo, possibleWalletContext of
      Just walletInfo, Just walletContext -> provider walletInfoCtx ((/\) <$> possibleWalletInfo <*> possibleWalletContext) $
        [ DOM.div { className: "container" } $ DOM.div { className: "row position-relative" } $ DOM.div { className: "col-6 mx-auto position-absolute top-10px start-50 translate-middle-x z-index-popover" }
            $ DOM.div { className: "container-xl" }
            $ DOM.div { className: "row" }
            $ messagePreview msgHub
        , topNavbar
        , appError
        -- FIXME:
        --  * we should probably move this whole container to message hub
        --  * adding here margins etc. can break the layout consistency
        , ReactContext.consumer msgHubProps.ctx \_ ->
            pure $ offcanvas
              { onHide: setCheckingNotifications false
              , placement: Offcanvas.placement.end
              , show: checkingNotifications -- && (not $ List.null msgs)
              , scroll: false
              }
              [ DOM.div { className: "p-3 overflow-auto" } $ messageBox msgHub
              ]

        -- This section appeared on click
        -- , Monoid.guard configuringWallet do
        --     let
        --       jsx = subcomponents.connectWallet
        --         { currentlyConnected: possibleWalletInfo
        --         , onWalletConnect: \result -> do
        --             case result of
        --               ConnectWallet.Connected walletInfo -> do
        --                 let
        --                   WalletInfo { name } = walletInfo
        --                 msgHubProps.add $ Success $ DOOM.text $ "Connected to " <> String.upperCaseFirst name
        --                 setWalletInfo (Just walletInfo)
        --               ConnectWallet.ConnectionError _ -> pure unit
        --               ConnectWallet.NoWallets -> pure unit
        --             setConfiguringWallet false
        --         , onDismiss: setConfiguringWallet false
        --         , inModal: true
        --         }
        --     jsx
        , subcomponents.contractListComponent
            { walletInfo
            , walletContext
            , possibleContracts
            , contractMapInitialized
            , notSyncedYetInserts
            , submittedWithdrawalsInfo
            , possibleInitialModalAction: (NewContract <<< Just) <$> props.possibleInitialContract
            , setPage: props.setPage
            }
        , footer
        ]
      _, _ -> fragment
        [ topNavbar
        , appError
        , landingPage { setWalletInfo: setWalletInfo <<< Just, overlay: isJust possibleWalletInfo }
        , footer
        ]

