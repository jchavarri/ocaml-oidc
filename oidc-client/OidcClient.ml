type client = Register of Oidc.Client.meta | Client of Oidc.Client.t

type 'store t = {
  kv : (module KeyValue.KV with type value = string and type store = 'store);
  store : 'store;
  client : Oidc.Client.t;
  http_client : Piaf.Client.t;
  provider_uri : Uri.t;
  redirect_uri : Uri.t;
}

let map_piaf_err (x : ('a, Piaf.Error.t) Lwt_result.t) :
    ('a, [> `Msg of string ]) Lwt_result.t =
  Lwt_result.map_err (fun e -> `Msg (Piaf.Error.to_string e)) x

let make (type store)
    ~(kv : (module KeyValue.KV with type value = string and type store = store))
    ~(store : store) ~redirect_uri ~provider_uri ~client :
    (store t, Piaf.Error.t) Lwt_result.t =
  let (module KV) = kv in
  let open Lwt_result.Syntax in
  let open Lwt_result.Infix in
  let* http_client = Piaf.Client.create provider_uri in
  let+ client =
    match client with
    | Client c -> Lwt_result.return c
    | Register client_meta ->
        let* discovery =
          Internal.discover ~kv ~store ~http_client ~provider_uri
        in
        Internal.register ~http_client ~client_meta ~discovery
        >|= fun dynamic ->
        Oidc.Client.of_dynamic_and_meta ~dynamic ~meta:client_meta
  in
  { kv; store; client; http_client; provider_uri; redirect_uri }

let discover t =
  Internal.discover ~kv:t.kv ~store:t.store ~http_client:t.http_client
    ~provider_uri:t.provider_uri

let get_jwks t =
  Internal.jwks ~kv:t.kv ~store:t.store ~http_client:t.http_client
    ~provider_uri:t.provider_uri

let get_token ~code t =
  let open Lwt_result.Infix in
  let open Lwt_result.Syntax in
  let* discovery = discover t in
  let token_path = Uri.of_string discovery.token_endpoint |> Uri.path in
  let body =
    Uri.add_query_params' Uri.empty
      [
        ("grant_type", "authorization_code");
        ("scope", "openid");
        ("code", code);
        ("client_id", t.client.id);
        ("client_secret", t.client.secret |> CCOpt.get_or ~default:"secret");
        ("redirect_uri", t.redirect_uri |> Uri.to_string);
      ]
    |> Uri.query |> Uri.encoded_of_query |> Piaf.Body.of_string
  in
  Piaf.Client.post t.http_client
    ~headers:
      [
        ("Content-Type", "application/x-www-form-urlencoded");
        ("Accept", "application/json");
      ]
    ~body token_path
  >>= Internal.to_string_body >|= Oidc.TokenResponse.of_string

let get_and_validate_id_token ?nonce ~code t =
  let open Lwt_result.Syntax in
  let* jwks = get_jwks t |> map_piaf_err in
  let* token_response = get_token ~code t |> map_piaf_err in
  let* discovery = discover t |> map_piaf_err in
  ( match Jose.Jwt.of_string token_response.id_token with
  | Ok jwt -> (
      if jwt.header.alg = `None then
        Oidc.Jwt.validate ?nonce ~client:t.client ~issuer:discovery.issuer jwt
        |> CCResult.map (fun _ -> token_response)
      else
        match Oidc.Jwks.find_jwk ~jwt jwks with
        | Some jwk ->
            Oidc.Jwt.validate ?nonce ~client:t.client ~issuer:discovery.issuer
              ~jwk jwt
            |> CCResult.map (fun _ -> token_response)
        (* When there is only 1 key in the jwks we can try with that according to the OIDC spec *)
        | None when List.length jwks.keys = 1 ->
            let jwk = List.hd jwks.keys in
            Oidc.Jwt.validate ?nonce ~client:t.client ~issuer:discovery.issuer
              ~jwk jwt
            |> CCResult.map (fun _ -> token_response)
        | None -> Error (`Msg "Could not find JWK") )
  | Error e -> Error e )
  |> Lwt.return

let get_auth_result ?nonce ~uri ~state t =
  match (Uri.get_query_param uri "state", Uri.get_query_param uri "code") with
  | None, _ -> Error (`Msg "No state returned") |> Lwt.return
  | _, None -> Error (`Msg "No code returned") |> Lwt.return
  | Some returned_state, Some code ->
      if returned_state <> state then
        Error (`Msg "State doesn't match") |> Lwt.return
      else get_and_validate_id_token ?nonce ~code t

let register t client_meta =
  discover t
  |> Lwt_result.map (fun discovery ->
         Internal.register ~http_client:t.http_client ~client_meta ~discovery)

let get_auth_parameters ?scope ?claims ~nonce ~state t =
  Oidc.Parameters.make ?scope ?claims t.client ~nonce ~state
    ~redirect_uri:t.redirect_uri

let get_auth_uri ?scope ?claims ~nonce ~state t =
  let query =
    get_auth_parameters ?scope ?claims ~nonce ~state t
    |> Oidc.Parameters.to_query
  in
  discover t
  |> Lwt_result.map (fun (discovery : Oidc.Discover.t) ->
         discovery.authorization_endpoint ^ query)

let get_userinfo ~jwt ~token t =
  let open Lwt_result.Infix in
  let open Lwt_result.Syntax in
  let* discovery = discover t |> map_piaf_err in
  let user_info_path = Uri.of_string discovery.userinfo_endpoint |> Uri.path in
  let userinfo =
    Piaf.Client.get t.http_client
      ~headers:
        [ ("Authorization", "Bearer " ^ token); ("Accept", "application/json") ]
      user_info_path
    >>= Internal.to_string_body |> map_piaf_err
  in
  Lwt_result.bind userinfo (fun userinfo ->
      Internal.validate_userinfo ~jwt userinfo |> Lwt.return)

module Microsoft = struct
  let make (type store)
      ~(kv :
         (module KeyValue.KV with type value = string and type store = store))
      ~(store : store) ~app_id ~tenant_id:_ ~secret ~redirect_uri =
    let provider_uri =
      Uri.of_string "https://login.microsoftonline.com/common/v2.0"
    in
    let client =
      Client
        {
          id = app_id;
          response_types = [ "code" ];
          grant_types = [ "authorization_code" ];
          redirect_uris = [ "https://login.microsoftonline.com/common/v2.0" ];
          secret;
          token_endpoint_auth_method = "client_secret_post";
        }
    in
    make ~kv ~store ~redirect_uri ~provider_uri ~client
end

module KeyValue = KeyValue
