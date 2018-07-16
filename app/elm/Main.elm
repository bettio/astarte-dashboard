module Main exposing (..)

import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (onClick, onInput)
import Http
import Ports
import Navigation exposing (Location)
import Json.Decode as Decode exposing (at, string, Value)
import Json.Encode as Encode


-- Types

import Route exposing (Route, RealmRoute)
import Types.FlashMessage as FlashMessage exposing (FlashMessage, Severity)
import Types.Session as Session exposing (Session, Credentials, LoginType(..))
import Types.ExternalMessage exposing (ExternalMsg(..))


-- Pages

import Page.Login as Login
import Page.Interfaces as Interfaces
import Page.InterfaceBuilder as InterfaceBuilder
import Page.Triggers as Triggers
import Page.TriggerBuilder as TriggerBuilder
import Page.RealmSettings as RealmSettings


-- bootstrap components

import Bootstrap.Grid as Grid
import Bootstrap.ListGroup as ListGroup
import Bootstrap.Navbar as Navbar
import Bootstrap.Utilities.Spacing as Spacing


main =
    Navigation.programWithFlags (NewLocation)
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        }



-- MODEL


type alias Model =
    { selectedPage : Page
    , flashMessages : List FlashMessage
    , messageCounter : Int
    , session : Session
    , navbarState : Navbar.State
    , configParameters : Config
    }


init : Value -> Location -> ( Model, Cmd Msg )
init jsParam location =
    let
        rmApiUrl =
            Decode.decodeValue (at [ "realmManagementApiUrl" ] string) jsParam
                |> Result.toMaybe
                |> Maybe.withDefault ""

        defaultAuthUrl =
            Decode.decodeValue (at [ "defaultAuthUrl" ] string) jsParam
                |> Result.toMaybe

        previousSession =
            Decode.decodeValue (at [ "previousSession" ] string) jsParam
                |> Result.toMaybe
                |> Maybe.andThen (Decode.decodeString Session.decoder >> Result.toMaybe)

        hostUrl =
            location.protocol ++ "//" ++ location.host

        defaultLoginType =
            case defaultAuthUrl of
                Nothing ->
                    OAuth

                Just url ->
                    OAuthFromConfig url

        initialSession =
            case previousSession of
                Nothing ->
                    Session.empty
                        |> Session.setAuthUrl defaultAuthUrl
                        |> Session.setRealmManagementApiUrl rmApiUrl
                        |> Session.setHostUrl hostUrl
                        |> Session.setLoginType defaultLoginType

                Just prevSession ->
                    prevSession
                        |> Session.setHostUrl hostUrl

        ( initialPage, initialCommand, updatedSession ) =
            Route.fromLocation location
                |> processRoute initialSession

        ( navbarState, navbarCmd ) =
            Navbar.initialState NavbarMsg

        configFromJavascript =
            { realmManagementApiUrl = rmApiUrl
            , defaultAuthUrl = defaultAuthUrl
            }

        initialModel =
            { selectedPage = initialPage
            , flashMessages = []
            , messageCounter = 0
            , session = updatedSession
            , navbarState = navbarState
            , configParameters = configFromJavascript
            }
    in
        ( initialModel
        , Cmd.batch
            [ navbarCmd
            , initialCommand
            ]
        )


type alias Config =
    { realmManagementApiUrl : String
    , defaultAuthUrl : Maybe String
    }


type Page
    = Public PublicPage
    | Realm String RealmPage


type PublicPage
    = LoginPage Login.Model


type RealmPage
    = InterfacesPage Interfaces.Model
    | InterfaceBuilderPage InterfaceBuilder.Model
    | TriggersPage Triggers.Model
    | TriggerBuilderPage TriggerBuilder.Model
    | RealmSettingsPage RealmSettings.Model



-- UPDATE


type Msg
    = NavbarMsg Navbar.State
    | NewLocation Location
    | SetRoute Route
    | UpdateSession (Maybe Session)
    | LoginMsg Login.Msg
    | InterfacesMsg Interfaces.Msg
    | InterfaceBuilderMsg InterfaceBuilder.Msg
    | RealmSettingsMsg RealmSettings.Msg
    | TriggersMsg Triggers.Msg
    | TriggerBuilderMsg TriggerBuilder.Msg


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        NavbarMsg state ->
            ( { model | navbarState = state }
            , Cmd.none
            )

        NewLocation location ->
            setRoute model <| Route.fromLocation location

        SetRoute route ->
            setRoute model ( Just route, Nothing )

        UpdateSession Nothing ->
            ( { model
                | session =
                    Session.empty
                        |> Session.setRealmManagementApiUrl model.configParameters.realmManagementApiUrl
              }
            , Cmd.none
            )

        UpdateSession (Just session) ->
            ( { model | session = session }
            , Cmd.none
            )

        -- Page specific messages
        _ ->
            updatePage model.selectedPage msg model


updatePage : Page -> Msg -> Model -> ( Model, Cmd Msg )
updatePage page msg model =
    case page of
        Public publicPage ->
            updatePublicPage publicPage msg model

        Realm realm realmPage ->
            updateRealmPage realm realmPage msg model


updatePublicPage : PublicPage -> Msg -> Model -> ( Model, Cmd Msg )
updatePublicPage publicPage msg model =
    case ( msg, publicPage ) of
        ( LoginMsg subMsg, LoginPage subModel ) ->
            let
                ( newModel, pageCommand, externalMsg ) =
                    Login.update model.session subMsg subModel

                updatedModel =
                    handleExternalMessage model externalMsg
            in
                ( { updatedModel | selectedPage = Public (LoginPage newModel) }
                , Cmd.map LoginMsg pageCommand
                )

        -- Ignore messages from not matching pages
        ( _, _ ) ->
            ( model
            , Cmd.none
            )


updateRealmPage : String -> RealmPage -> Msg -> Model -> ( Model, Cmd Msg )
updateRealmPage realm realmPage msg model =
    let
        ( page, command, externalMsg ) =
            case ( msg, realmPage ) of
                ( InterfacesMsg subMsg, InterfacesPage subModel ) ->
                    updateRealmPageHelper realm (Interfaces.update model.session subMsg subModel) (InterfacesMsg) (InterfacesPage)

                ( InterfaceBuilderMsg subMsg, InterfaceBuilderPage subModel ) ->
                    updateRealmPageHelper realm (InterfaceBuilder.update model.session subMsg subModel) (InterfaceBuilderMsg) (InterfaceBuilderPage)

                ( RealmSettingsMsg subMsg, RealmSettingsPage subModel ) ->
                    updateRealmPageHelper realm (RealmSettings.update model.session subMsg subModel) (RealmSettingsMsg) (RealmSettingsPage)

                ( TriggersMsg subMsg, TriggersPage subModel ) ->
                    updateRealmPageHelper realm (Triggers.update model.session subMsg subModel) (TriggersMsg) (TriggersPage)

                ( TriggerBuilderMsg subMsg, TriggerBuilderPage subModel ) ->
                    updateRealmPageHelper realm (TriggerBuilder.update model.session subMsg subModel) (TriggerBuilderMsg) (TriggerBuilderPage)

                -- Ignore messages from not matching pages
                ( _, _ ) ->
                    ( model.selectedPage, Cmd.none, Noop )

        updatedModel =
            handleExternalMessage model externalMsg
    in
        ( { updatedModel | selectedPage = page }
        , command
        )


updateRealmPageHelper : String -> ( a, Cmd b, ExternalMsg ) -> (b -> Msg) -> (a -> RealmPage) -> ( Page, Cmd Msg, ExternalMsg )
updateRealmPageHelper realm ( newSubModel, pageCommand, msg ) subMsgTagger pageTagger =
    ( Realm realm (pageTagger newSubModel)
    , Cmd.map subMsgTagger pageCommand
    , msg
    )


handleExternalMessage : Model -> ExternalMsg -> Model
handleExternalMessage model externalMsg =
    case externalMsg of
        Noop ->
            model

        AddFlashMessage severity message ->
            let
                newFlashMessage =
                    FlashMessage.new model.messageCounter message severity
            in
                { model
                    | flashMessages = model.flashMessages ++ [ newFlashMessage ]
                    , messageCounter = model.messageCounter + 1
                }

        DismissFlashMessage messageId ->
            { model | flashMessages = List.filter (\message -> message.id /= messageId) model.flashMessages }


pageInit : RealmRoute -> Credentials -> Session -> ( Page, Cmd Msg )
pageInit realmRoute credentials session =
    case realmRoute of
        Route.Auth _ _ ->
            -- already logged in
            initInterfacesPage session credentials.realm

        Route.Logout ->
            let
                ( page, command ) =
                    initLoginPage session

                logoutPath =
                    case session.loginType of
                        Token ->
                            Route.toString <| Route.RealmSelection (Just "token")

                        OAuthFromConfig authUrl ->
                            [ authUrl, "/logout?redirect_uri=", Http.encodeUri session.hostUrl ]
                                |> String.concat

                        OAuth ->
                            let
                                authUrl =
                                    session.authUrl
                                        |> Maybe.withDefault ""
                            in
                                [ authUrl, "/logout?redirect_uri=", Http.encodeUri session.hostUrl ]
                                    |> String.concat
            in
                ( page
                , Cmd.batch
                    [ Ports.storeSession Nothing
                    , Navigation.load <| logoutPath
                    ]
                )

        Route.RealmSettings ->
            initSettingsPage session credentials.realm

        Route.ListInterfaces ->
            initInterfacesPage session credentials.realm

        Route.NewInterface ->
            initInterfaceBuilderPage Nothing session credentials.realm

        Route.ShowInterface name major ->
            initInterfaceBuilderPage (Just ( name, major )) session credentials.realm

        Route.ListTriggers ->
            initTriggersPage session credentials.realm

        Route.NewTrigger ->
            initTriggerBuilderPage Nothing session credentials.realm

        Route.ShowTrigger name ->
            initTriggerBuilderPage (Just name) session credentials.realm


initLoginPage : Session -> ( Page, Cmd Msg )
initLoginPage session =
    let
        ( initialSubModel, initialPageCommand ) =
            Login.init session
    in
        ( Public (LoginPage initialSubModel)
        , Cmd.map LoginMsg initialPageCommand
        )


initInterfacesPage : Session -> String -> ( Page, Cmd Msg )
initInterfacesPage session realm =
    let
        ( initialModel, initialCommand ) =
            Interfaces.init session
    in
        ( Realm realm (InterfacesPage initialModel)
        , Cmd.map InterfacesMsg initialCommand
        )


initInterfaceBuilderPage : Maybe ( String, Int ) -> Session -> String -> ( Page, Cmd Msg )
initInterfaceBuilderPage maybeInterfaceId session realm =
    let
        ( initialModel, initialCommand ) =
            InterfaceBuilder.init maybeInterfaceId session
    in
        ( Realm realm (InterfaceBuilderPage initialModel)
        , Cmd.map InterfaceBuilderMsg initialCommand
        )


initTriggersPage : Session -> String -> ( Page, Cmd Msg )
initTriggersPage session realm =
    let
        ( initialModel, initialCommand ) =
            Triggers.init session
    in
        ( Realm realm (TriggersPage initialModel)
        , Cmd.map TriggersMsg initialCommand
        )


initTriggerBuilderPage : Maybe String -> Session -> String -> ( Page, Cmd Msg )
initTriggerBuilderPage maybeTriggerName session realm =
    let
        ( initialModel, initialCommand ) =
            TriggerBuilder.init maybeTriggerName session
    in
        ( Realm realm (TriggerBuilderPage initialModel)
        , Cmd.map TriggerBuilderMsg initialCommand
        )


initSettingsPage : Session -> String -> ( Page, Cmd Msg )
initSettingsPage session realm =
    let
        ( initialModel, initialCommand ) =
            RealmSettings.init session
    in
        ( Realm realm (RealmSettingsPage initialModel)
        , Cmd.map RealmSettingsMsg initialCommand
        )



-- ROUTE PROCESSING


setRoute : Model -> ( Maybe Route, Maybe String ) -> ( Model, Cmd Msg )
setRoute model ( maybeRoute, maybeToken ) =
    setPage model <| processRoute model.session ( maybeRoute, maybeToken )


setPage : Model -> ( Page, Cmd Msg, Session ) -> ( Model, Cmd Msg )
setPage model ( page, command, session ) =
    ( { model
        | selectedPage = page
        , session = session
      }
    , command
    )


processRoute : Session -> ( Maybe Route, Maybe String ) -> ( Page, Cmd Msg, Session )
processRoute session ( maybeRoute, maybeToken ) =
    case maybeRoute of
        Nothing ->
            case session.credentials of
                Nothing ->
                    initLoginPage session
                        ==> session

                _ ->
                    processRealmRoute maybeToken Route.ListInterfaces session

        Just Route.Root ->
            case session.credentials of
                Nothing ->
                    initLoginPage session
                        ==> session

                _ ->
                    processRealmRoute maybeToken Route.ListInterfaces session

        Just (Route.RealmSelection loginTypeString) ->
            case session.credentials of
                Nothing ->
                    let
                        loginType =
                            case loginTypeString of
                                Just "token" ->
                                    Token

                                _ ->
                                    OAuth

                        updatedSession =
                            Session.setLoginType loginType session
                    in
                        initLoginPage updatedSession
                            ==> updatedSession

                _ ->
                    processRealmRoute maybeToken Route.ListInterfaces session

        Just (Route.Realm realmRoute) ->
            processRealmRoute maybeToken realmRoute session


processRealmRoute : Maybe String -> RealmRoute -> Session -> ( Page, Cmd Msg, Session )
processRealmRoute maybeToken realmRoute session =
    case session.credentials of
        Just credentials ->
            case maybeToken of
                Just token ->
                    -- update token
                    let
                        updatedCredentials =
                            { credentials | token = token }

                        updatedSession =
                            session
                                |> Session.setCredentials (Just updatedCredentials)

                        ( page, command ) =
                            pageInit realmRoute updatedCredentials updatedSession
                    in
                        ( page
                        , Cmd.batch [ storeSession updatedSession, command ]
                        , updatedSession
                        )

                Nothing ->
                    -- access granted
                    pageInit realmRoute credentials session
                        ==> session

        Nothing ->
            case realmRoute of
                Route.Auth maybeRealm maybeUrl ->
                    case ( maybeRealm, maybeToken ) of
                        ( Just realm, Just token ) ->
                            -- login into realm
                            let
                                updatedCredentials =
                                    { realm = realm
                                    , token = token
                                    }

                                updatedSession =
                                    session
                                        |> Session.setCredentials (Just updatedCredentials)
                                        |> Session.setAuthUrl maybeUrl

                                ( page, command ) =
                                    pageInit Route.ListInterfaces updatedCredentials updatedSession
                            in
                                ( page
                                , Cmd.batch [ storeSession updatedSession, command ]
                                , updatedSession
                                )

                        _ ->
                            -- missing parameters
                            initLoginPage session
                                ==> session

                _ ->
                    -- not authorized
                    initLoginPage session
                        ==> session



-- VIEW


view : Model -> Html Msg
view model =
    div []
        [ Grid.containerFluid
            [ class "bg-light" ]
            [ renderNavbar model ]
        , renderPage model model.selectedPage
        ]


renderNavbar : Model -> Html Msg
renderNavbar model =
    case model.selectedPage of
        Public (LoginPage _) ->
            text ""

        _ ->
            Navbar.config NavbarMsg
                |> Navbar.withAnimation
                |> Navbar.collapseMedium
                |> Navbar.container
                |> Navbar.brand
                    [ href "#" ]
                    [ img
                        [ src "/logo.svg"
                        , style [ ( "height", "3em" ) ]
                        , Spacing.mr2
                        ]
                        []
                    , text "Realm Management"
                    ]
                |> Navbar.items
                    [ (pageLinkRenderer model.selectedPage isInterfacesRelated)
                        [ href <| Route.toString (Route.Realm Route.ListInterfaces) ]
                        [ text "Interfaces" ]
                    , (pageLinkRenderer model.selectedPage isTriggersRelated)
                        [ href <| Route.toString (Route.Realm Route.ListTriggers) ]
                        [ text "Triggers" ]
                    , (pageLinkRenderer model.selectedPage isSettingsRelated)
                        [ href <| Route.toString (Route.Realm Route.RealmSettings) ]
                        [ text "Settings" ]
                    ]
                |> Navbar.customItems
                    (renderLogoutButton model.session.credentials)
                |> Navbar.view model.navbarState


pageLinkRenderer : Page -> (Page -> Bool) -> (List (Attribute msg) -> List (Html msg) -> Navbar.Item msg)
pageLinkRenderer page checker =
    if (checker page) then
        Navbar.itemLinkActive
    else
        Navbar.itemLink


isInterfacesRelated : Page -> Bool
isInterfacesRelated page =
    case page of
        Realm _ (InterfacesPage _) ->
            True

        Realm _ (InterfaceBuilderPage _) ->
            True

        _ ->
            False


isTriggersRelated : Page -> Bool
isTriggersRelated page =
    case page of
        Realm _ (TriggersPage _) ->
            True

        Realm _ (TriggerBuilderPage _) ->
            True

        _ ->
            False


isSettingsRelated : Page -> Bool
isSettingsRelated page =
    case page of
        Realm _ (RealmSettingsPage _) ->
            True

        _ ->
            False


renderLogoutButton : Maybe Credentials -> List (Navbar.CustomItem Msg)
renderLogoutButton maybeCredentials =
    case maybeCredentials of
        Just _ ->
            [ Navbar.textItem []
                [ a
                    [ href <| Route.toString (Route.Realm Route.Logout) ]
                    [ text "Logout" ]
                ]
            ]

        Nothing ->
            []


renderPage : Model -> Page -> Html Msg
renderPage model page =
    case page of
        Public publicPage ->
            renderPublicPage model.flashMessages publicPage

        Realm realm realmPage ->
            renderProtectedPage model.flashMessages realm realmPage


renderPublicPage : List FlashMessage -> PublicPage -> Html Msg
renderPublicPage flashMessages page =
    case page of
        LoginPage submodel ->
            Login.view submodel flashMessages
                |> Html.map LoginMsg


renderProtectedPage : List FlashMessage -> String -> RealmPage -> Html Msg
renderProtectedPage flashMessages realm page =
    case page of
        InterfacesPage submodel ->
            Interfaces.view submodel flashMessages
                |> Html.map InterfacesMsg

        InterfaceBuilderPage submodel ->
            InterfaceBuilder.view submodel flashMessages
                |> Html.map InterfaceBuilderMsg

        TriggersPage submodel ->
            Triggers.view submodel flashMessages
                |> Html.map TriggersMsg

        RealmSettingsPage submodel ->
            RealmSettings.view submodel flashMessages
                |> Html.map RealmSettingsMsg

        TriggerBuilderPage submodel ->
            TriggerBuilder.view submodel flashMessages
                |> Html.map TriggerBuilderMsg



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Navbar.subscriptions model.navbarState NavbarMsg
        , Sub.map UpdateSession sessionChange
        , pageSubscriptions model.selectedPage
        ]


pageSubscriptions : Page -> Sub Msg
pageSubscriptions page =
    case page of
        Realm _ (InterfaceBuilderPage submodel) ->
            Sub.map InterfaceBuilderMsg <| InterfaceBuilder.subscriptions submodel

        _ ->
            Sub.none


sessionChange : Sub (Maybe Session)
sessionChange =
    Ports.onSessionChange (Decode.decodeValue Session.decoder >> Result.toMaybe)


storeSession : Session -> Cmd msg
storeSession session =
    Session.encode session
        |> Encode.encode 0
        |> Just
        |> Ports.storeSession



-- Helper functions


(==>) : ( a, b ) -> c -> ( a, b, c )
(==>) ( oa, ob ) oc =
    ( oa, ob, oc )
