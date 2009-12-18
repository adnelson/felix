(* name binding test harness *)

Flx_version_hook.set_version ()

let print_help () =
  Flx_flxopt.print_options ();
  exit 0

let reverse_return_parity = ref false;;

try
  let argc = Array.length Sys.argv in
  if argc <= 1
  then begin
    print_endline "usage: flxg --key=value ... filename; -h for help";
    raise (Flx_exceptions.Exit 0)
  end
  ;
  let raw_options = Flx_getopt.parse_options Sys.argv in
  let compiler_options = Flx_flxopt.get_felix_options raw_options in
  reverse_return_parity := compiler_options.Flx_mtypes2.reverse_return_parity;
  let syms = Flx_mtypes2.make_syms compiler_options in

  if Flx_getopt.check_keys raw_options ["h"; "help"] then print_help ();

  if Flx_getopt.check_key raw_options "version" then print_endline
    ("Felix Version " ^ !Flx_version.version_data.Flx_version.version_string);

  if compiler_options.Flx_mtypes2.print_flag then begin
    print_string "//Include directories = ";
    List.iter (fun d -> print_string (d ^ " "))
    compiler_options.Flx_mtypes2.include_dirs;
    print_endline ""
  end
  ;

  let filename =
    match Flx_getopt.get_key_value raw_options "" with
    | Some s -> s
    | None -> exit 0
  in
  let filebase = filename in
  let input_file_name = filebase ^ ".flx"
  and iface_file_name = filebase ^ ".fix"
  and module_name =
    let n = String.length filebase in
    let i = ref (n-1) in
    while !i <> -1 && filebase.[!i] <> '/' do decr i done;
    String.sub filebase (!i+1) (n - !i - 1)
  in

  (* PARSE THE IMPLEMENTATION FILE *)
  print_endline ("//Parsing Implementation " ^ input_file_name);
  let parser_state = List.fold_left
    (Flx_parse.parse_file
      ~include_dirs:compiler_options.Flx_mtypes2.include_dirs)
    (Flx_parse.make_parser_state (fun stmt stmts -> stmt :: stmts) [])
    (compiler_options.Flx_mtypes2.auto_imports @ [input_file_name])
  in
  let parse_tree = List.rev (Flx_parse.parser_data parser_state) in
  let have_interface = Sys.file_exists iface_file_name in
  print_endline (Flx_print.string_of_compilation_unit parse_tree);
  print_endline "//PARSE OK";

  let include_dirs =
    (* (Filename.dirname input_file_name) :: *)
    compiler_options.Flx_mtypes2.include_dirs in
  let compiler_options = { compiler_options with
    Flx_mtypes2.include_dirs = include_dirs } in
  let syms = { syms with
    Flx_mtypes2.compiler_options = compiler_options } in
  let desugar_state = Flx_desugar.make_desugar_state module_name syms in
  let asms = Flx_desugar.desugar_stmts desugar_state parse_tree in

  let root = !(syms.Flx_mtypes2.counter) in
  print_endline ("//Top level module '" ^ module_name ^ "' has index " ^
    Flx_print.string_of_bid root);

  (* Bind the assemblies. *)
  print_endline "//BINDING EXECUTABLE CODE";
  print_endline "//-----------------------";

  let bind_state = Flx_bind.make_bind_state syms in
  let bsym_table = Flx_bsym_table.create () in
  Flx_bind.bind_asms bind_state bsym_table asms;
  print_endline "//Binding complete";

  Flx_print.print_bsym_table bsym_table

with x -> Flx_terminate.terminate !reverse_return_parity x
;;
