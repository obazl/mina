open Core
open Async
open Cmdliner
open Integration_test_lib

type test = string * (module Test_functor_intf)

type inputs = {test: test; coda_image: string}

let tests : test list =
  [ ( "block-production"
    , (module Block_production_test.Make : Test_functor_intf) ) ]

let to_or_error = Deferred.map ~f:Or_error.return

let report_test_errors error_set =
  let open Test_error in
  let open Test_error.Set in
  let errors =
    List.concat
      [ List.map error_set.soft_errors ~f:(fun err -> (`Soft, err))
      ; List.map error_set.hard_errors ~f:(fun err -> (`Hard, err)) ]
  in
  if List.length errors > 0 then (
    Print.eprintf "%s=== Errors encountered while running tests ===%s\n"
      Bash_colors.red Bash_colors.none ;
    let sorted_errors =
      List.sort errors ~compare:(fun (_, err1) (_, err2) ->
          Time.compare (occurrence_time err1) (occurrence_time err2) )
    in
    List.iter sorted_errors ~f:(fun (error_type, error) ->
        let color =
          match error_type with
          | `Soft ->
              Bash_colors.yellow
          | `Hard ->
              Bash_colors.red
        in
        Print.eprintf "    %s%s%s\n" color (to_string error) Bash_colors.none
    ) ;
    Out_channel.(flush stderr) ;
    exit 1 )
  else Deferred.unit

let main inputs =
  (* TODO: abstract over which engine is in use, allow engine to be set form CLI *)
  let module Engine = Integration_test_cloud_engine in
  let test_name, (module Test) = inputs.test in
  let (module T) =
    (module Test (Engine)
    : Test_intf
      with type network = Engine.Network.t
       and type log_engine = Engine.Log_engine.t )
  in
  let logger = Logger.create () in
  let images =
    { Container_images.coda= inputs.coda_image
    ; user_agent= "codaprotocol/coda-user-agent:0.1.5"
    ; bots= "codaprotocol/coda-bots:0.0.13-beta-1"
    ; points= "codaprotocol/coda-points-hack:32b.4" }
  in
  let network_config =
    Engine.Network_config.expand ~logger ~test_name ~test_config:T.config
      ~images
  in
  (* resources which require additional cleanup at end of test *)
  let net_manager_ref : Engine.Network_manager.t option ref = ref None in
  let log_engine_ref : Engine.Log_engine.t option ref = ref None in
  let cleanup_deferred_ref = ref None in
  let dispatch_cleanup reason (test_error : 'a Malleable_error.t) =
    let cleanup () =
      let test_error_with_cleanup_result =
        let open Malleable_error.Let_syntax in
        let%bind res =
          let open Deferred.Let_syntax in
          match%bind test_error with
          | Ok {Malleable_error.Accumulator.computation_result= _; soft_errors}
            ->
              Malleable_error.return
                (Test_error.Set.from_list_soft
                   (List.map soft_errors ~f:Test_error.internal_error_from_raw))
          | Error
              { Malleable_error.Hard_fail.hard_error= hard_err
              ; Malleable_error.Hard_fail.soft_errors } ->
              Malleable_error.return
                (Test_error.Set.merge
                   (Test_error.Set.hard_singleton
                      (Test_error.internal_error_from_raw hard_err))
                   (Test_error.Set.from_list_soft
                      (List.map soft_errors
                         ~f:Test_error.internal_error_from_raw)))
        in
        let%bind remote_error_set =
          Option.value_map !log_engine_ref
            ~default:(Malleable_error.return Test_error.Set.empty)
            ~f:Engine.Log_engine.destroy
        in
        let%map () =
          Option.value_map !net_manager_ref ~default:Malleable_error.ok_unit
            ~f:
              (Fn.compose
                 (Deferred.bind ~f:Malleable_error.return)
                 Engine.Network_manager.cleanup)
        in
        Test_error.Set.merge remote_error_set res
      in
      match%bind
        Malleable_error.lift_error_set test_error_with_cleanup_result
      with
      | Ok (remote_error_set, internal_error_set) ->
          report_test_errors
            (Test_error.Set.merge remote_error_set internal_error_set)
      | Error internal_error_set ->
          report_test_errors internal_error_set
    in
    let%bind test_error_str =
      Malleable_error.hard_error_to_string test_error
    in
    match !cleanup_deferred_ref with
    | Some deferred ->
        [%log error]
          "additional call to cleanup testnet while already cleaning up \
           ($reason, $hard_error)"
          ~metadata:
            [("reason", `String reason); ("hard_error", `String test_error_str)] ;
        deferred
    | None ->
        [%log info] "cleaning up testnet ($reason, $error)"
          ~metadata:
            [("reason", `String reason); ("hard_error", `String test_error_str)] ;
        let deferred = cleanup () in
        cleanup_deferred_ref := Some deferred ;
        deferred
  in
  (* run test while gracefully recovering handling exceptions and interrupts *)
  Signal.handle Signal.terminating ~f:(fun signal ->
      [%log info] "handling signal %s" (Signal.to_string signal) ;
      let error =
        Error.of_string
        @@ Printf.sprintf "received signal %s" (Signal.to_string signal)
      in
      don't_wait_for
        (dispatch_cleanup "signal received" (Malleable_error.hard_error error))
  ) ;
  let%bind monitor_test_result =
    Monitor.try_with ~extract_exn:true (fun () ->
        let open Malleable_error.Let_syntax in
        let%bind net_manager =
          Deferred.bind ~f:Malleable_error.return
            (Engine.Network_manager.create network_config)
        in
        net_manager_ref := Some net_manager ;
        let%bind network =
          Deferred.bind ~f:Malleable_error.return
            (Engine.Network_manager.deploy net_manager)
        in
        let%bind log_engine =
          Engine.Log_engine.create ~logger ~network ~on_fatal_error:(fun () ->
              don't_wait_for
                (dispatch_cleanup "log engine fatal error"
                   (Malleable_error.return ())) )
        in
        log_engine_ref := Some log_engine ;
        T.run network log_engine )
  in
  let test_result =
    match monitor_test_result with
    | Ok malleable_error ->
        Deferred.return malleable_error
    | Error exn ->
        Malleable_error.hard_error (Error.of_exn exn)
  in
  let%bind () = dispatch_cleanup "test completed" test_result in
  exit 0

let start inputs =
  never_returns
    (Async.Scheduler.go_main ~main:(fun () -> don't_wait_for (main inputs)) ())

(* TODO: move required args to positions instead of flags, or provide reasonable defaults to make them optional *)
let () =
  let test =
    (* we nest the tests in a redundant index so that we still get the name back after cmdliner evaluates the argument *)
    let indexed_tests =
      List.map tests ~f:(fun (name, test) -> (name, (name, test)))
    in
    let doc = "The name of the test to execute." in
    Arg.(required & pos 0 (some (enum indexed_tests)) None & info [] ~doc)
  in
  let coda_image =
    let doc = "Identifier of the coda docker image to test." in
    let env = Arg.env_var "CODA_IMAGE" ~doc in
    Arg.(
      required
      & opt (some string) None
      & info ["coda-image"] ~env ~docv:"CODA_IMAGE" ~doc)
  in
  (*
  let coda_automation_location =
    let doc =
      "Location of the coda automation repository to use when deploying the \
       network."
    in
    let env = Arg.env_var "CODA_AUTOMATION_LOCATION" ~doc in
    Arg.(
      required
      & opt (some string) None
      & info
          ["coda-automation-location"]
          ~env ~docv:"CODA_AUTOMATION_LOCATION" ~doc)
  in
  *)
  let inputs =
    let cons_inputs test coda_image = {test; coda_image} in
    Term.(const cons_inputs $ test $ coda_image)
  in
  let test_executive_term =
    Term.(
      const start $ inputs
      $ const (module Block_production_test.Make : Test_functor_intf))
  in
  let test_executive_info =
    let doc = "Run coda integration test(s)." in
    Term.info "test_executive" ~doc ~exits:Term.default_exits
  in
  Term.(exit @@ eval (test_executive_term, test_executive_info))
