%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------
-module(emqx_persistent_session_ds_gc_worker).

-behaviour(gen_server).

-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include_lib("stdlib/include/qlc.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-include("emqx_persistent_session_ds.hrl").

%% API
-export([
    start_link/0
]).

%% `gen_server' API
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

%% call/cast/info records
-record(gc, {}).

%%--------------------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%--------------------------------------------------------------------------------
%% `gen_server' API
%%--------------------------------------------------------------------------------

init(_Opts) ->
    ensure_gc_timer(),
    State = #{},
    {ok, State}.

handle_call(_Call, _From, State) ->
    {reply, error, State}.

handle_cast(_Cast, State) ->
    {noreply, State}.

handle_info(#gc{}, State) ->
    try_gc(),
    ensure_gc_timer(),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------------------
%% Internal fns
%%--------------------------------------------------------------------------------

ensure_gc_timer() ->
    Timeout = emqx_config:get([session_persistence, session_gc_interval]),
    _ = erlang:send_after(Timeout, self(), #gc{}),
    ok.

try_gc() ->
    %% Only cores should run GC.
    CoreNodes = mria_membership:running_core_nodelist(),
    Res = global:trans(
        {?MODULE, self()},
        fun() -> ?tp_span(debug, ds_session_gc, #{}, start_gc()) end,
        CoreNodes,
        %% Note: we set retries to 1 here because, in rare occasions, GC might start at the
        %% same time in more than one node, and each one will abort the other.  By allowing
        %% one retry, at least one node will (hopefully) get to enter the transaction and
        %% the other will abort.  If GC runs too fast, both nodes might run in sequence.
        %% But, in that case, GC is clearly not too costly, and that shouldn't be a problem,
        %% resource-wise.
        _Retries = 1
    ),
    case Res of
        aborted ->
            ?tp(ds_session_gc_lock_taken, #{}),
            ok;
        ok ->
            ok
    end.

now_ms() ->
    erlang:system_time(millisecond).

start_gc() ->
    do_gc(more).

zombie_session_ms() ->
    NowMS = now_ms(),
    GCInterval = emqx_config:get([session_persistence, session_gc_interval]),
    BumpInterval = emqx_config:get([session_persistence, last_alive_update_interval]),
    TimeThreshold = max(GCInterval, BumpInterval) * 3,
    ets:fun2ms(
        fun(
            #session{
                id = DSSessionId,
                last_alive_at = LastAliveAt,
                conninfo = #{expiry_interval := EI}
            }
        ) when
            LastAliveAt + EI + TimeThreshold =< NowMS
        ->
            DSSessionId
        end
    ).

do_gc(more) ->
    GCBatchSize = emqx_config:get([session_persistence, session_gc_batch_size]),
    MS = zombie_session_ms(),
    {atomic, Next} = mria:transaction(?DS_MRIA_SHARD, fun() ->
        Res = mnesia:select(?SESSION_TAB, MS, GCBatchSize, write),
        case Res of
            '$end_of_table' ->
                done;
            {[], Cont} ->
                %% since `GCBatchsize' is just a "recommendation" for `select', we try only
                %% _once_ the continuation and then stop if it yields nothing, to avoid a
                %% dead loop.
                case mnesia:select(Cont) of
                    '$end_of_table' ->
                        done;
                    {[], _Cont} ->
                        done;
                    {DSSessionIds0, _Cont} ->
                        do_gc_(DSSessionIds0),
                        more
                end;
            {DSSessionIds0, _Cont} ->
                do_gc_(DSSessionIds0),
                more
        end
    end),
    do_gc(Next);
do_gc(done) ->
    ok.

do_gc_(DSSessionIds) ->
    lists:foreach(fun emqx_persistent_session_ds:destroy_session/1, DSSessionIds),
    ?tp(ds_session_gc_cleaned, #{session_ids => DSSessionIds}),
    ok.
