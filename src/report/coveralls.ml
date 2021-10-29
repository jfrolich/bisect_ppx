(* This file is part of Bisect_ppx, released under the MIT license. See
   LICENSE.md for details, or visit
   https://github.com/aantron/bisect_ppx/blob/master/LICENSE.md. *)



(* The actual Coveralls report. *)

let file_json indent in_file resolver visited points =
  Util.info "Processing file '%s'..." in_file;
  match resolver in_file with
  | None ->
    Util.info "... file not found";
    None
  | Some resolved_in_file ->
    let digest = Digest.to_hex (Digest.file resolved_in_file) in
    let line_counts =
      Util.line_counts in_file resolved_in_file visited points in
    let scounts =
      line_counts
      |> List.map (function
        | None -> "null"
        | Some nb -> Printf.sprintf "%d" nb)
    in
    let coverage = String.concat "," scounts in
    let indent_strings indent l =
      let i = String.make indent ' ' in
      List.map (fun s -> i ^ s) l
    in
    Some begin
      [
        "{";
        Printf.sprintf "    \"name\": \"%s\"," in_file;
        Printf.sprintf "    \"source_digest\": \"%s\"," digest;
        Printf.sprintf "    \"coverage\": [%s]" coverage;
        "}";
      ]
      |> indent_strings indent
      |> String.concat "\n"
    end

let output_of command =
  let channel = Unix.open_process_in command in
  let line = input_line channel in
  match Unix.close_process_in channel with
  | WEXITED 0 ->
    line
  | _ ->
    Printf.eprintf "Error: command failed: '%s'\n%!" command;
    exit 1

let metadata name field =
  output_of ("git log -1 --pretty=format:'" ^ field ^ "'")
  |> String.escaped
  |> Printf.sprintf "\"%s\":\"%s\"" name

let output
    ~to_file ~service_name ~service_number ~service_job_id ~service_pull_request
    ~repo_token ~git ~parallel ~coverage_files ~coverage_paths ~source_paths
    ~ignore_missing_files ~expect ~do_not_expect =

  let data, points =
    Input.load_coverage coverage_files coverage_paths expect do_not_expect in
  let resolver = Util.search_file source_paths ignore_missing_files in

  let git =
    if not git then
      ""
    else
      let metadata =
        String.concat "," [
          metadata "id" "%H";
          metadata "author_name" "%an";
          metadata "author_email" "%ae";
          metadata "committer_name" "%cn";
          metadata "committer_email" "%ce";
          metadata "message" "%s";
        ]
      in
      let branch = output_of "git rev-parse --abbrev-ref HEAD" in
      Printf.sprintf
        "    \"git\":{\"head\":{%s},\"branch\":\"%s\",\"remotes\":{}},"
        metadata branch
  in

  Util.mkdirs (Filename.dirname to_file);
  let file_jsons =
    Hashtbl.fold begin fun in_file visited acc ->
      let maybe_json = file_json 8 in_file resolver visited points in
      match maybe_json with
      | None -> acc
      | Some s -> s::acc
    end data []
  in
  let repo_params =
    [
      "service_name", (String.trim service_name);
      "service_number", (String.trim service_number);
      "service_job_id", (String.trim service_job_id);
      "service_pull_request", (String.trim service_pull_request);
      "repo_token", (String.trim repo_token);
    ]
    |> List.filter (fun (_, v) -> (String.length v) > 0)
    |> List.map (fun (n, v) -> Printf.sprintf "    \"%s\": \"%s\"," n v)
    |> String.concat "\n"
  in
  let parallel =
    if parallel then
      "    \"parallel\": true,"
    else
      ""
  in
  let write ch =
    Util.output_strings
      [
        "{";
        repo_params;
        git;
        parallel;
        "    \"source_files\": [";
        (String.concat ",\n" file_jsons);
        "    ]";
        "}";
      ]
      []
      ch
  in
  match to_file with
  | "-" -> write stdout
  | f -> Bisect_common.try_out_channel false f write



(* Automatically detecting the CI and sending the report to third-party
   services. *)

type ci = [
  | `CircleCI
  | `Travis
  | `GitHub
]

module CI :
sig
  val detect : unit -> ci option
  val pretty_name : ci -> string
  val name_in_report : ci -> string
  val job_id_variable : ci -> string
end =
struct
  let environment_variable name value result k =
    match Sys.getenv name with
    | value' when value' = value -> Some result
    | _ -> k ()
    | exception Not_found -> k ()

  let detect () =
    environment_variable "CIRCLECI" "true" `CircleCI @@ fun () ->
    environment_variable "TRAVIS" "true" `Travis @@ fun () ->
    environment_variable "GITHUB_ACTIONS" "true" `GitHub @@ fun () ->
    None

  let pretty_name = function
    | `CircleCI -> "CircleCI"
    | `Travis -> "Travis"
    | `GitHub -> "GitHub Actions"

  let name_in_report = function
    | `CircleCI -> "circleci"
    | `Travis -> "travis-ci"
    | `GitHub -> "github"

  let job_id_variable = function
    | `CircleCI -> "CIRCLE_BUILD_NUM"
    | `Travis -> "TRAVIS_JOB_ID"
    | `GitHub -> "GITHUB_RUN_NUMBER"
end

type coverage_service = [
  | `Codecov
  | `Coveralls
]

module Coverage_service :
sig
  val from_argument : string option -> coverage_service option
  val pretty_name : coverage_service -> string
  val report_filename : coverage_service -> string
  val send_command : coverage_service -> string
  val needs_pull_request_number : ci -> coverage_service -> string option
  val needs_repo_token : ci -> coverage_service -> bool
  val repo_token_variables : coverage_service -> string list
  val needs_git_info : ci -> coverage_service -> bool
end =
struct
  let from_argument = function
    | None -> None
    | Some "Codecov" -> Some `Codecov
    | Some "Coveralls" -> Some `Coveralls
    | Some other -> Util.error "send-to: unknown coverage service '%s'" other

  let pretty_name = function
    | `Codecov -> "Codecov"
    | `Coveralls -> "Coveralls"

  let report_filename _ =
    "coverage.json"

  let send_command = function
    | `Codecov ->
      "curl -s https://codecov.io/bash | bash -s -- -Z -f coverage.json"
    | `Coveralls ->
      "curl -L -F json_file=@./coverage.json https://coveralls.io/api/v1/jobs"

  let needs_pull_request_number ci service =
    match ci, service with
    | `CircleCI, `Coveralls -> Some "CIRCLE_PULL_REQUEST"
    | `GitHub, `Coveralls -> Some "PULL_REQUEST_NUMBER"
    | _ -> None

  let needs_repo_token ci service =
    match ci, service with
    | `CircleCI, `Coveralls -> true
    | `GitHub, `Coveralls -> true
    | _ -> false

  let repo_token_variables = function
    | `Codecov -> ["CODECOV_TOKEN"]
    | `Coveralls -> ["COVERALLS_REPO_TOKEN"]

  let needs_git_info ci service =
    match ci, service with
    | `CircleCI, `Coveralls -> true
    | `GitHub, `Coveralls -> true
    | _ -> false
end

let output_and_send
    ~to_file ~service ~service_name ~service_number ~service_job_id
    ~service_pull_request ~repo_token ~git ~parallel ~dry_run ~coverage_files
    ~coverage_paths ~source_paths ~ignore_missing_files ~expect ~do_not_expect =

  let coverage_service = Coverage_service.from_argument service in

  let to_file =
    match coverage_service with
    | None ->
      to_file
    | Some service ->
      let report_file = Coverage_service.report_filename service in
      Util.info "will write coverage report to '%s'" report_file;
      report_file
  in

  let ci =
    lazy begin
      match CI.detect () with
      | Some ci ->
        Util.info "detected CI: %s" (CI.pretty_name ci);
        ci
      | None ->
        Util.error "unknown CI service or not in CI"
    end
  in

  let service_name =
    match coverage_service, service_name with
    | Some _, "" ->
      let service_name = CI.name_in_report (Lazy.force ci) in
      Util.info "using service name '%s'" service_name;
      service_name
    | _ ->
      service_name
  in

  let service_job_id =
    match coverage_service, service_job_id with
    | Some _, "" ->
      let job_id_variable = CI.job_id_variable (Lazy.force ci) in
      Util.info "using job ID variable $%s" job_id_variable;
      begin match Sys.getenv job_id_variable with
      | value ->
        value
      | exception Not_found ->
        Util.error "expected job id in $%s" job_id_variable
      end
    | _ ->
      service_job_id
  in

  let service_pull_request =
    match coverage_service, service_pull_request with
    | Some service, "" ->
      let needs =
        Coverage_service.needs_pull_request_number (Lazy.force ci) service in
      begin match needs with
      | None ->
        service_pull_request
      | Some pr_variable ->
        match Sys.getenv pr_variable with
        | value ->
          Util.info "using PR number variable $%s" pr_variable;
          value
        | exception Not_found ->
          Util.info "$%s not set" pr_variable;
          service_pull_request
      end
    | _ ->
      service_pull_request
  in

  let repo_token =
    match coverage_service, repo_token with
    | Some service, "" ->
      if Coverage_service.needs_repo_token (Lazy.force ci) service then begin
        let repo_token_variables =
          Coverage_service.repo_token_variables service in
        let rec try_variables = function
          | variable::more ->
            begin match Sys.getenv variable with
            | exception Not_found ->
              try_variables more
            | value ->
              Util.info "using repo token variable $%s" variable;
              value
            end
          | [] ->
            Util.error
              "expected repo token in $%s" (List.hd repo_token_variables)
        in
        try_variables repo_token_variables
      end
      else
        repo_token
    | _ ->
      repo_token
  in

  let git =
    match coverage_service, git with
    | Some service, false ->
      if Coverage_service.needs_git_info (Lazy.force ci) service then begin
        Util.info "including git info";
        true
      end
      else
        false
    | _ ->
      git
  in

  output
    ~to_file ~service_name ~service_number ~service_job_id ~service_pull_request
    ~repo_token ~git ~parallel ~coverage_files ~coverage_paths ~source_paths
    ~ignore_missing_files ~expect ~do_not_expect;

  match coverage_service with
  | None ->
    ()
  | Some coverage_service ->
    let name = Coverage_service.pretty_name coverage_service in
    let command = Coverage_service.send_command coverage_service in
    Util.info "sending to %s with command:" name;
    Util.info "%s" command;
    if not dry_run then begin
      let exit_code = Sys.command command in
      let report = Coverage_service.report_filename coverage_service in
      if Sys.file_exists report then begin
        Util.info "deleting '%s'" report;
        Sys.remove report
      end;
      exit exit_code
    end