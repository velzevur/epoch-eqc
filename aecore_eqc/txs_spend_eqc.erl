%%% -*- erlang-indent-level:2; indent-tabs-mode: nil -*-
%%% @author Thomas Arts
%%% @doc Spend transaction
%%%
%%% Created : 24 May 2019 by Thomas Arts

-module(txs_spend_eqc).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").

-compile([export_all, nowarn_export_all]).

-record(account, {key, amount, nonce, names_owned = []}).

%% -- State and state functions ----------------------------------------------
initial_state() ->
    #{}.

%% -- Common pre-/post-conditions --------------------------------------------

%% --- Operation: spend ---
spend_pre(S) ->
    maps:is_key(accounts, S).

%% here we should add spending to oracle and contract
%% aeser_id:specialize_type(Recv),
%% names are always accounts, hard coded in tx_processor
spend_args(#{height := Height} = S) ->
    ?LET([Sender, To], [gen_account_key(1, 49, S),
                             frequency([{10, {account,  gen_account_key(2, 1, S)}},
                                        {2, {oracle, gen_account_key(1, 49, S)}},      %% There is no check account really is an oracle!
                                        %% {1, {contract, gen_contract_id(1, 100, maps:get(contracts, S))}},
                                        {2, {name, elements(maps:keys(maps:get(named_accounts, S, #{})) ++ [<<"ta.test">>])}}])],
         [Sender,
          case To of
              {account, Receiver} -> {account, Receiver};
              {oracle,  Receiver} -> {oracle, Receiver};
              {contract, ContractId} -> {contract, ContractId};
              {name, Name} -> {name, Name}
          end,
          #{sender_id => aeser_id:create(account, Sender),  %% The sender is asserted to never be a name.
            recipient_id =>
                case To of
                    {account, Receiver} ->
                        aeser_id:create(account, Receiver);
                    {oracle, Receiver} ->
                        aeser_id:create(oracle, Receiver);
                    {contract, ContractId} ->
                        aeser_id:create(contract, ContractId);
                    {name, Name} ->
                        aeser_id:create(name, aens_hash:name_hash(Name))
                end,
            amount => gen_spend_amount(account(S, Sender)),
            fee => gen_fee(Height),
            nonce => gen_nonce(),
            payload => utf8()}]).

spend_valid(#{height := Height} = S, [Sender, {ReceiverTag, Receiver}, Tx]) ->
    is_account(S, Sender)
    andalso maps:get(nonce, Tx) == good
    andalso check_balance(S, Sender, maps:get(amount, Tx) + maps:get(fee, Tx))
    andalso valid_fee(Height, Tx)
    andalso case ReceiverTag of
                account -> true;
                oracle -> true; %% an account is generated if oracle does not exsists
                contract -> true;
                name     -> maps:is_key(Receiver, maps:get(named_accounts, S, #{}))
            end.

spend_tx(S, [Sender, _, Tx]) ->
    NonceTx = update_nonce(S, Sender, Tx),
    aec_spend_tx:new(NonceTx).

spend_next(S, _Value, [Sender, TaggedReceiver, Tx] = Args) ->
    case spend_valid(S, Args) of
        false -> S;
        true  ->
            #{ amount := Amount, fee := Fee } = Tx,
            case resolve_account(S, TaggedReceiver) of
                false -> S;
                {contract, ContractId} ->
                     reserve_fee(Fee,
                                bump_and_charge(Sender, Amount + Fee,
                                                credit_contract(ContractId, Amount, S)));
                RKey ->
                    reserve_fee(Fee,
                                bump_and_charge(Sender, Amount + Fee,
                                                credit(RKey, Amount, S)))
            end
    end.

spend_post(S, Args, Res) ->
    Correct = spend_valid(S, Args),
    case Res of
        {error, _} when Correct -> eq(Res, ok);
        {error, _}              -> true;
        ok when Correct         -> true;
        ok                      -> eq(ok, {error, '_'})
    end.

spend_features(S, [Sender, {Tag, Receiver}, _Tx] = Args, Res) ->
    Correct = spend_valid(S, Args),
    [{correct,  if Correct -> spend; true -> false end}] ++
        [ {spend_to, self} || Sender == Receiver andalso Correct] ++
        [ {spend_to, Tag} || Sender =/= Receiver andalso Correct] ++
        [ {spend, Res}].




%% -- weight ---------------------------------------------------------------
weight(_S, spend) -> 20;
weight(_S, _) -> 0.

%% -- Transactions modifiers

update_nonce(S, Sender, #{nonce := Nonce} = Tx) ->
    case lists:keyfind(Sender, #account.key, maps:get(accounts, S, [])) of
        false ->
            Tx#{nonce => 1};
        Account ->
            case Nonce of
                good ->
                    Tx#{nonce => Account#account.nonce };
                {bad, N} ->
                    Tx#{nonce => max(0, Account#account.nonce + N) }
            end
    end.

%% -- State update and query functions ---------------------------------------


resolve_account(S, {name, Name}) -> maps:get(Name, maps:get(named_accounts, S, #{}), false);
resolve_account(_, {contract, Key}) -> {contract, Key};
resolve_account(_, {_, Key})     -> Key.

check_balance(S, Key, Amount) ->
     (account(S, Key))#account.amount >= Amount.


on_account(Key, Fun, S = #{accounts := Accounts}) ->
    Upd = fun(Acc = #account{ key = Key1 }) when Key1 == Key -> Fun(Acc);
             (Acc) -> Acc end,
    S#{ accounts => lists:map(Upd, Accounts) }.

credit(Key, Amount, S = #{ accounts := Accounts }) ->
    case is_account(S, Key) of
        true ->
            on_account(Key, fun(Acc) -> Acc#account{ amount = Acc#account.amount + Amount } end, S);
        false ->
            S#{ accounts => Accounts ++ [#account{ key = Key, amount = Amount, nonce = 1 }] }
    end.

credit_contract(_Key, _Amount, S = #{ contracts := _Contracts}) ->
    S.

charge(Key, Amount, S) -> credit(Key, -Amount, S).

bump_nonce(Key, S) ->
    on_account(Key, fun(Acc) -> Acc#account{ nonce = Acc#account.nonce + 1 } end, S).

reserve_fee(Fee, S = #{fees := Fees, height := H}) ->
    S#{fees => Fees ++ [{Fee, H}]}.

bump_and_charge(Key, Fee, S) ->
    bump_nonce(Key, charge(Key, Fee, S)).

add(Tag, X, S) ->
    S#{ Tag => maps:get(Tag, S, []) ++ [X] }.

remove(Tag, X, I, S) ->
    S#{ Tag := lists:keydelete(X, I, maps:get(Tag, S)) }.

get(S, Tag, Key, I) ->
    lists:keyfind(Key, I, maps:get(Tag, S)).

account_keys(#{accounts := Accounts}) ->
    [ Account#account.key || Account <- Accounts].


%% --- local helpers ------

is_account(#{accounts := Accounts}, Key) ->
    lists:keymember(Key, #account.key, Accounts).

account_key(#account{key = Key}) ->
    Key.

account_nonce(#account{nonce = Nonce}) ->
    Nonce.

valid_fee(H, #{ fee := Fee }) ->
    Fee >= 20000 * minimum_gas_price(H).   %% not precise, but we don't generate fees in the shady range


account(#{accounts := Accounts}, Key) ->
    lists:keyfind(Key, #account.key, Accounts).


%% -- Generators -------------------------------------------------------------
minimum_gas_price(H) ->
    aec_governance:minimum_gas_price(H).

gen_account_key(New, Exist, #{accounts := Accounts, keys := Keys}) ->
    case [ Key || Key <- maps:keys(Keys), not lists:keymember(Key, #account.key, Accounts) ] of
        [] ->
            elements([ account_key(A) || A <- Accounts]);
        NewKeys ->
            weighted_default(
              {Exist, elements([ account_key(A) || A <- Accounts])},
              {New,   oneof(NewKeys)})
    end.

gen_nonce() ->
    weighted_default({49, good}, {1, {bad, elements([-1, 1, -5, 5, 10000])}}).

gen_spend_amount(false) ->
    choose(0, 10000000);
gen_spend_amount(#account{ amount = X }) ->
    weighted_default({49, round(X / 5)}, {1, choose(0, 10000000)}).

gen_fee(H) ->
    frequency([{29, ?LET(F, choose(20000, 30000), F * minimum_gas_price(H))},
                {1,  ?LET(F, choose(0, 15000), F)},   %%  too low (and very low for hard fork)
                {1,  ?LET(F, choose(0, 15000), F * minimum_gas_price(H))}]).    %% too low

gen_fee_above(H, Amount) ->
    frequency([{29, ?LET(F, choose(Amount, Amount + 10000), F * minimum_gas_price(H))},
                {1,  ?LET(F, choose(0, Amount - 5000), F)},   %%  too low (and very low for hard fork)
                {1,  ?LET(F, choose(0, Amount - 5000), F * minimum_gas_price(H))}]).    %% too low