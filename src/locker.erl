-module(locker).
-behavior(gen_server).
-export([
    % Main public API
    lend/2,		% Give the lock to another process
    lock/1,
    lock/2,
    islocked/1,
    trylock/1,
    unlock/1,
    withlock/2,	% Execute function while holding a lock

    % Service functions
    dump/1,
    dump/2,
    state_screen/0,
    start_link/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export_type([resource/0, withlock_fun/1]).
-type resource() :: term().
-type withlock_fun(Out) :: fun (() -> Out).


start_link() -> gen_server:start_link({local, locker}, ?MODULE, [], []).

%% Unconditionally lock the resource
-spec lock(resource()) -> ok.
lock(Term) -> 
    case lock(Term, infinity) of
        ok -> ok;
        fail -> throw({lock, failed, Term})
    end.

%% Lock the resource with a specified timeout.
-spec lock(resource(), timeout()) -> ok | fail.
lock(Term, Timeout) ->
    case gen_server:call(locker, {lock, Term}) of
        ok -> ok;
        fail -> fail;
        {wait, Ref} -> %(A link to a locker process has been created)
            receive
                {locked, Ref} -> ok
            after
                Timeout -> unlock(Term), fail
            end
    end.

%% Some debugging
dump(Term) -> dump(term, Term).
dump(term, Term) -> gen_server:call(locker, {dump, term, Term});
dump(pid, Pid) -> gen_server:call(locker, {dump, pid, Pid}).

%% Try locking the resource
-spec trylock(resource()) -> ok | fail.
trylock(Term) -> gen_server:call(locker, {trylock, Term}).

%% Unlock the resource
-spec unlock(resource()) -> ok | fail.
unlock(Term) -> gen_server:call(locker, {unlock, Term, normal}).

%% Check if we have this resource locked
-spec islocked(resource()) -> true | false.
islocked(Term) -> gen_server:call(locker, {isLockedByMe, Term}).

%% Move the held lock to another process.
-spec lend(resource(), pid()) -> ok | fail.
lend(Term, Pid) -> gen_server:call(locker, {lend_lock, Term, Pid}).

%% Execute the function while holding a lock.
-spec withlock(resource(), withlock_fun(Out)) -> Out.
withlock(Term, Fun) when is_function(Fun, 0) ->
    lock(Term),
    try Fun() of
        Value -> unlock(Term), Value
    catch
        Class:Reason ->
            unlock(Term),
            erlang:raise(Class, Reason, erlang:get_stacktrace())
    end.

state_screen() -> gen_server:call(locker, state_screen).

-record(state, { term2pids, pid2terms }).

init([]) ->
    process_flag(trap_exit, true),
    process_flag(priority, high),
    {ok, #state {
            term2pids = ets:new(locker_storage, [set, private]),
            pid2terms = ets:new(locker_storage, [bag, private])
    }}.

handle_call(state_screen, _, State) ->
    {reply, state_screen(State), State};
handle_call(Query, {FromPid,_},
            #state{term2pids = TermsT, pid2terms = PidsT} = State) 
        ->
    {reply, lockerOperation(Query, FromPid, {TermsT, PidsT}), State};
handle_call(_Query, _From, State) -> {noreply, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({'EXIT', Pid, _Info}, #state{term2pids = TermsT, pid2terms = PidsT} = State) ->
    lockerOperation(unlockByPid, Pid, {TermsT, PidsT}),
    {noreply, State};
handle_info(_Info, State) -> {noreply, State}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

terminate(_Reason, _State) -> ok.

% Autotesting aid


% Internal functions

state_screen(#state{term2pids = TermsT, pid2terms = PidsT}) ->
    lists:flatten([
            "Terms to pids:\n",
            lists:map(fun({T, N, _, WQ}) ->
                        [ io_lib:format("~p (~p locks #1):", [T, N]),
                         [io_lib:format(" ~p", [P]) || {P, _} <- queue:to_list(WQ)],
                         "\n"]
                end, ets:tab2list(TermsT)),
            "Pids to terms:\n",
            [io_lib:format("~p: ~p~n", tuple_to_list(Tuple))
             || Tuple = {_, _} <- ets:tab2list(PidsT)]
            ]).

lockerOperation({unlock, LockTerm, Mode}, Pid, {TermsT, PidsT}) ->
    case ets:lookup(TermsT, LockTerm) of
        [{_,NLocks,Pid,_}] when NLocks > 1, Mode /= forceMultipleUnlocks ->
            % Leading process may hold several locks on a term. Remove one.
            ets:update_counter(TermsT, LockTerm, -1), ok;
        [{_,_,Pid,WaitQ}] ->
            % Forget about this process locking this Term.
            ets:delete_object(PidsT, {Pid, LockTerm}),
            selectNextLockLead(LockTerm, queue:tail(WaitQ), TermsT),
            ok;
        [_] -> fail;	% Term was instantly re-locked by someone else
        [] -> fail	% Term was never locked
    end;
lockerOperation(unlockByPid, Pid, {_, PidsT} = Tabs) ->
    % A process locking all these terms has gone. Cleanup.
    LockedTerms = ets:lookup(PidsT, Pid),
    ets:delete(PidsT, Pid),
    lists:foreach(fun({_, Term}) ->
                lockerOperation({unlock, Term, forceMultipleUnlocks}, Pid, Tabs)
        end, LockedTerms);

lockerOperation({lock, LockTerm}, Pid, {TermsT, _PidsT} = Tabs) ->
    case ets:lookup(TermsT, LockTerm) of
        [] -> addRequestorToLock(LockTerm, Pid, Tabs);
        [{_,_,Pid,_}] ->
            ets:update_counter(TermsT, LockTerm, +1), ok;
        [{_,NLocks,LeadPid,WaitQ}] ->
            case is_process_alive(LeadPid) of
                true ->
                    addRequestorToLock(LockTerm, Pid, Tabs, NLocks, LeadPid, WaitQ);
                false ->
                    %io:format("Lead process ~p is DEAD for locking ~p~n~s~n",
                    %	[LeadPid, LockTerm, state_screen(#state{term2pids=TermsT,pid2terms=_PidsT})]),
                    lockerOperation(unlockByPid, LeadPid, Tabs),
                    %io:format("Second pass: ~s~n",
                    %	[state_screen(#state{term2pids=TermsT,pid2terms=_PidsT})]),
                    lockerOperation({lock, LockTerm}, Pid, Tabs)
            end
    end;
lockerOperation({trylock, LockTerm}, Pid, {TermsT, _PidsT} = Tabs) ->
    case ets:lookup(TermsT, LockTerm) of
        [] -> addRequestorToLock(LockTerm, Pid, Tabs);
        [{_,_N,Pid,_WaitQ}] -> ets:update_counter(TermsT, LockTerm, +1), ok;
        _ -> fail
    end;
lockerOperation({isLockedByMe, LockTerm}, Pid, {TermsT,_PidsT}) ->
    case ets:lookup(TermsT, LockTerm) of
        [{_, _, Pid, _}] -> true;
        _ -> false
    end;
lockerOperation({lend_lock, LockTerm, NewPid}, Pid, {TermsT,PidsT}) ->
    case ets:lookup(TermsT, LockTerm) of
        [{_,_,Pid,_WaitQ}] when Pid == NewPid -> ok;
        [{_,1,Pid,WaitQ}] ->
            link(NewPid),
            ets:insert(PidsT, {NewPid, LockTerm}),
            selectNextLockLead(LockTerm,
                               queue:cons({NewPid, noref}, WaitQ), TermsT),
            ok;
        _ -> fail
    end;

lockerOperation({dump, term, LockTerm}, _Pid, {TermsT, PidsT}) ->
    case ets:lookup(TermsT, LockTerm) of
        [] -> {[], empty, empty};
        [{_,_,Pid,_}] = Lock -> {Lock, Pid, ets:lookup(PidsT, Pid)}
    end;
lockerOperation({dump, pid, Pid}, _, {_TermsT, PidsT}) ->
    ets:lookup(PidsT, Pid).

addRequestorToLock(LockTerm, Pid, {TermsT, PidsT}) ->
    link(Pid),
    ets:insert(TermsT, {LockTerm, 1, Pid, queue:from_list([{Pid,noref}])}),
    ets:insert(PidsT, {Pid, LockTerm}),
    ok.
addRequestorToLock(LockTerm, Pid, {TermsT, PidsT}, NLocks, LeadPid, WaitQ) ->
    link(Pid),
    Ref = make_ref(),
    NewQ = queue:snoc(WaitQ, {Pid,Ref}),
    ets:insert(TermsT, {LockTerm, NLocks, LeadPid, NewQ}),
    ets:insert(PidsT, {Pid, LockTerm}),
    {wait, Ref}.	% Wait in line for your turn to lock.

selectNextLockLead(LockTerm, WaitQ, TermsT) ->
    case queue:is_empty(WaitQ) of
        % No one is interested, forget this locking term.
        true -> ets:delete(TermsT, LockTerm);
        false ->
            % Wake up the next first process in the queue
            {WPid, WRef} = queue:head(WaitQ),
            case is_process_alive(WPid) of
                true ->
                    WQList = queue:to_list(WaitQ),
                    NList = [P ! {locked, R}
                             || {P, R} <- WQList, P == WPid],
                    NewWait = [E || E = {P, _} <- WQList, P /= WPid],
                    ets:insert(TermsT, {LockTerm, length(NList), WPid,
                                        queue:from_list([{WPid, WRef} | NewWait])});
                false ->
                    selectNextLockLead(LockTerm, queue:tail(WaitQ), TermsT)
            end
    end.

