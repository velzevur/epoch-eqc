%%% -*- erlang-indent-level:2; indent-tabs-mode: nil -*-
%%% @author Thomas Arts
%%%         ./rebar3 as eqc, test shell --apps=aesophia
%%% @doc Idea: give a list of models. For any command name, e.g. mine, try all models for this command.
%%%            All preconditions should be true and all nest state updates should be performed.
%%%            Only the acutal command in one module (the generator module having the _args) is executed.
%%%
%%% @end
%%% Created : 23 May 2019 by Thomas Arts

-module(transactions_eqc).

-include_lib("eqc/include/eqc.hrl").
%%-include_lib("eqc/include/eqc_merge_statem.hrl").
-import(eqc_statem, [more_commands/2, run_commands/1, check_command_names/2,
                     commands_length/1, call_features/1 ]).
-import(eqc_merge_statem, [ pretty_commands/4  %% Overwrite with specific pretty_commands
                    ]).

-compile([export_all, nowarn_export_all]).
-only_positive(false).

%% Possibly make this into a parameterized module
models(HardForks) ->
  [ {txs_core_eqc, maps:merge(#{hard_forks => HardForks}, txs_core_eqc:initial_state())}
  , txs_spend_eqc
  , txs_contracts_eqc
  , txs_names_eqc
  , txs_oracles_eqc
  ].

%% hidden and for stats, but should not be needed
model_atoms() ->
  lists:map(fun({M, _}) -> M;
               (M) -> M
            end, models(dummy)).


%% --- Calling the SUT ---------------------------------------------

%% This should be generated automatically!
%% But Tx trick is rather nice and that cannot be done automatically
call(S, {call, M, Cmd, Args}) ->
  CmdTx = list_to_atom(lists:concat([Cmd, "_tx"])),
  CmdCall = list_to_atom(lists:concat([Cmd, "_call"])),
  case lists:member({CmdTx, 2}, M:module_info(exports)) of
    true ->
      case apply(M, CmdTx, [S, Args]) of
        {ok, Tx} ->
          try apply_transaction(maps:get(height, S), Tx)
          catch _:Reason ->
              {error, Reason}
          end;
        Error ->
          Error
      end;
    false ->
      case lists:member({CmdCall, 2}, M:module_info(exports)) of
        true ->
          apply(M, CmdCall, [S, Args]);
        false ->
          apply(M, Cmd, Args)
      end
  end.

apply_transaction(Height, Tx) ->
    Env      = aetx_env:tx_env(Height),
    Trees    = get(trees),

    case aetx:process(Tx, Trees, Env) of
        {ok, NewTrees, _NewEnv} ->
            put(trees, NewTrees),
            ok;
        Other ->
            Other
    end.

%% --- Property -----------------------------------




prop_txs() ->
  Forks = #{1=> 0, 2 => 3, 3 => 6, 4 => 9},
  prop_txs(Forks).

prop_txs(Forks) ->
    propsetup(Forks,
    eqc:dont_print_counterexample(
    in_parallel(
    ?FORALL(Cmds, more_commands(5, eqc_merge_statem:merge_commands(?MODULE, models(Forks))),
    begin
        put(trees, undefined),
        {H, S, Res} = run_commands(Cmds),
        Height = maps:get(height, S, 0),
        check_command_names(Cmds,
            measure(length, commands_length(Cmds),
            measure(height, Height,
            features(call_features(H),
            stats(call_features(H),
                  pretty_commands(?MODULE, Cmds, {H, S, Res},
                                  Res == ok))))))
    end)))).



stats(Fs, Prop) ->
  aggregate(Fs, Prop);
%% Terrrible. I need to know all Kinds before property runs to make this work: bleh.
stats(Features, Prop) ->
  {Atoms, Rest} = lists:partition(fun is_atom/1, Features),
  Kinds = lists:usort(lists:map(fun(T) -> element(1, T) end, Rest) ++
                        eqc_statem:apply({eqc_merge_statem, ?MODULE, model_atoms()}, all_command_names, [])),
  aggregate(with_title(atoms), Atoms,
     aggregate_feats(Kinds, Rest, Prop)).

aggregate_feats([], _, Prop) -> Prop;
aggregate_feats([Tag | Kinds], Features, Prop) ->
    {Tuples, Rest} = lists:partition(fun(X) -> element(1, X) == Tag end, Features),
    %% io:format("Tag ~p Tuples ~p\n",[Tag, Tuples]),
    aggregate(with_title(Tag), Tuples, aggregate_feats(Kinds, Rest, Prop)).

propsetup(Forks, Prop) ->
    ?SETUP(
    fun() ->
            _ = application:load(aecore),
            application:load(aesophia),  %% Since we do in_parallel, we may have a race in line 86 of aesophia_compiler
            [ txs_contracts_eqc:compile_contracts() || lists:member(txs_contracts_eqc, models(Forks)) ],
            HardForksTeardown = setup_hard_forks(Forks),
            DataDirTeardown = setup_data_dir(),
            fun() ->
                    DataDirTeardown(),
                    HardForksTeardown()
            end
    end, Prop).

setup_data_dir() ->
    %% make sure we can run in eqc/aecore_eqc
    {ok, Dir} = file:get_cwd(),
    %% Not asserting that configuration parameter is undefined so to ease experimenting in Erlang shell.
    case lists:reverse(filename:split(Dir)) of
        [_, "eqc" | _] ->
            application:set_env(setup, data_dir, "../../data");
        _ ->
            application:set_env(setup, data_dir, "data")
    end,
    fun() ->
            ok = application:unset_env(setup, data_dir)
    end.

setup_hard_forks(Forks) ->
    X = maps:from_list([ {integer_to_binary(K), V} || {K, V} <- maps:to_list(Forks)]),
    %% Not asserting that configuration parameter is undefined so to ease experimenting in Erlang shell.
    ok = application:set_env(aecore, hard_forks, X),
    fun() ->
            ok = application:unset_env(aecore, hard_forks)
    end.