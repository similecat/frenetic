open Core.Std
open Async.Std

let help args =
  match args with 
    | [ "run" ] -> 
      Format.printf 
        "@[usage: katnetic run local <filename> @\n@]"
    | [ "dump" ] -> 
      Format.printf 
        "@[usage: katnetic dump local [all|policies|flowtables] <number of switches> <filename> @\n@]"
    | _ -> 
      Format.printf "@[usage: katnetic <command> @\n%s@\n%s@\n@]"
	"  run    Compile and start the controller"  
	"  dump   Compile and dump flow table"

module Run = struct
  open NetKAT_LocalCompiler

  let main args =
    match args with
      | [filename]
      | ("local" :: [filename]) ->
        let main () =
          let learning = Learning.create () in
          let static = Async_NetKAT.create_from_file filename in
          Async_NetKAT_Controller.start (Async_NetKAT.union learning static) () in
        never_returns (Scheduler.go_main ~max_num_open_file_descrs:4096 ~main ())
      | _ -> help [ "run" ]
end

module Dump = struct
  open NetKAT_LocalCompiler

  let with_channel f chan =
    f (NetKAT_Parser.program NetKAT_Lexer.token (Lexing.from_channel chan))

  let with_file f filename =
    In_channel.with_file filename ~f:(with_channel f)

  module Local = struct

    let with_compile (sw : SDN_Types.switchId) (p : NetKAT_Types.policy) =
      let _ = 
        Format.printf "@[Compiling switch %Ld [size=%d]...@]%!"
          sw (NetKAT_Semantics.size p) in
      let t1 = Unix.gettimeofday () in
      let i = compile sw p in
      let t2 = Unix.gettimeofday () in
      let t = to_table i in
      let t3 = Unix.gettimeofday () in
      let _ = Format.printf "@[Done [ctime=%fs ttime=%fs tsize=%d]@\n@]%!"
        (t2 -. t1) (t3 -. t2) (List.length t) in
      t

    let flowtable (sw : SDN_Types.switchId) t =
      if List.length t > 0 then
        Format.printf "@[flowtable for switch %Ld:@\n%a@\n@\n@]%!"
          sw
          SDN_Types.format_flowTable t

    let policy p =
      Format.printf "@[%a@\n@\n@]%!" NetKAT_Pretty.format_policy p

    let local f sw_num p =
      (* NOTE(seliopou): This may not catch all ports, but it'll catch some of
       * 'em! Also, lol for loop.
       * *)
      for sw = 0 to sw_num do
        let swL = Int64.of_int sw in 
        let sw_p = NetKAT_Types.(Seq(Filter(Test(Switch swL)), p)) in 
        let t = with_compile swL sw_p in
        f swL t
      done

    let all sw_num p =
      policy p;
      local flowtable sw_num p

    let stats sw_num p =
      local (fun x y -> ()) sw_num p

    let main args =
      match args with
        | (sw_num :: [filename])
        | ("all"        :: [sw_num; filename]) -> with_file (all (int_of_string sw_num)) filename
        | ("policies"   :: [sw_num; filename]) -> with_file policy filename
        | ("flowtables" :: [sw_num; filename]) -> with_file (local flowtable (int_of_string sw_num)) filename
        | ("stats"      :: [sw_num; filename]) -> with_file (stats (int_of_string sw_num)) filename
        | _ -> 
          Format.printf 
            "@[usage: katnetic dump local [all|policies|flowtables|stats] <number of switches> <filename>@\n@]%!"
  end


  let main args  =
    match args with
      | ("local"     :: args') -> Local.main args'
      | _ -> help [ "dump" ]
end

let _ = 
  match Array.to_list Sys.argv with
    | (_ :: "run"  :: args) -> 
      Run.main args
    | (_ :: "dump" :: args) -> 
      Dump.main args
    | _ -> 
      help []
