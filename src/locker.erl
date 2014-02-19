%%% 
%%% Copyright (c) 2007, 2009 JackNyfe. All rights reserved.
%%% THIS SOFTWARE IS PROPRIETARY AND CONFIDENTIAL. DO NOT REDISTRIBUTE.
%%% 
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
	start_link/0,
	selftest/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link() -> gen_server:start_link({local, locker}, ?MODULE, [], []).

%% Unconditionally lock the resource
%% @spec lock(term()) -> ok
lock(Term) -> case lock(Term, infinity) of
		ok -> ok;
		fail -> throw({lock, failed, Term})
	      end.

%% Lock the resource with a specified timeout.
%% @spec lock(term(), Timeout) -> ok | fail
%% Types
%% 	Timeout = int() | infinity
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
%% @spec trylock(term()) -> ok | fail
trylock(Term) -> gen_server:call(locker, {trylock, Term}).

%% Unlock the resource
%% @spec unlock(term()) -> ok | fail
unlock(Term) -> gen_server:call(locker, {unlock, Term, normal}).

%% Check if we have this resource locked
%% @spec islocked(term()) -> true | false
islocked(Term) -> gen_server:call(locker, {isLockedByMe, Term}).

%% Move the held lock to another process.
%% @spec move(term(), pid()) -> ok | fail
lend(Term, Pid) -> gen_server:call(locker, {lend_lock, Term, Pid}).

%% Execute the function while holding a lock.
withlock(Term, Fun) ->
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
		}
	    }.

handle_call(state_screen, _, State) ->
	{reply, state_screen(State), State};
handle_call(Query, {FromPid,_},
		#state{term2pids = TermsT, pid2terms = PidsT} = State) ->
	{reply, lockerOperation(Query, FromPid, {TermsT, PidsT}), State};
handle_call(_Query, _From, State) -> {noreply, State}.

handle_cast(_Query, State) -> {noreply, State}.

handle_info({'EXIT', Pid, _Info}, #state{term2pids = TermsT, pid2terms = PidsT} = State) ->
	lockerOperation(unlockByPid, Pid, {TermsT, PidsT}),
	{noreply, State};
handle_info(_Info, State) -> {noreply, State}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.
terminate(_Reason, _State) -> ok.

% Autotesting aid

selftest() ->
	io:format("Autotesting ~p ~p~n", [?MODULE, self()]),
	Self = self(),
	ok = locker:lock(again),
	ok = locker:lock(again),	% Same process!
	io:format("1. Locker state:~n~s", [locker:state_screen()]),
	ok = locker:unlock(again),
	io:format("2. Locker state:~n~s", [locker:state_screen()]),
	ok = locker:unlock(again),	% Second unlocking is OK
	fail = locker:unlock(again),		% Unlock second time? No.
	ok = locker:lock(foo),
	ok = locker:lock(bar),
	fail = locker:unlock(nothing),
	ok = locker:trylock(foo),
	ok = locker:trylock(bar),
	ok = locker:trylock(baz),
	ok = locker:unlock(baz),
	io:format("=== 3. Locker state: ===~n~s===~n", [locker:state_screen()]),
	ok = locker:lock(double),
	io:format("=== 4. Locker state: ===~n~s===~n", [locker:state_screen()]),
	PPid = self(),
	P = spawn_link(fun () ->
		io:format("Ext: spawned ~p, parent ~p~n", [self(), PPid]),
		PPid ! {spawned, self()},
		io:format("Ext: double locking...~n"),
		ok = locker:lock(double),
		io:format("Ext: double unlocked~n"),
		receive unlocked -> ok end,
		io:format("Ext: L(lockedElsewhere)~n"),
		ok = locker:lock(lockedElsewhere),
		fail = locker:trylock(foo),
		ok = locker:lock(baz),
		io:format("Ext: done~n"),
		PPid ! {done, self()},
		receive finish -> io:format("Ext: got finish request...~n") end,
		timer:sleep(500),
		io:format("Ext: finished~n")
		end),
	receive {spawned, P} -> ok end,
	timer:sleep(500),
	io:format("=== 5. Locker state: ===~n~s===~n", [locker:state_screen()]),
	ok = locker:unlock(double),
	{[_], _, _} = locker:dump(double),
	P ! unlocked,
	{[_], _, _} = locker:dump(double),
	io:format("=== 6. Locker state: ===~n~s===~n", [locker:state_screen()]),
	io:format("Locker: waiting for external ~p to initialize~n", [P]),
	receive {done, P} -> io:format("Locker: external initialized~n") end,
	io:format("=== 7. Locker state: ===~n~s===~n", [locker:state_screen()]),
	ok = locker:unlock(foo),
	ok = locker:unlock(bar),
	ok = locker:unlock(foo),
	ok = locker:unlock(bar),
	fail = locker:unlock(bar),
	fail = locker:trylock(lockedElsewhere),
	false = locker:islocked(lockedElsewhere),
	fail = locker:trylock(baz),
	io:format("Locker: waiting for external ~p to finish~n", [P]),
	P ! finish,
	fail = locker:trylock(baz),
	io:format("Trying to lock something belonging to external process~n"),
	ok = locker:lock(lockedElsewhere),
	ok = locker:lock(baz),
	ok = locker:trylock(baz),	% (Abaz)
	true = locker:islocked(baz),	% (Bbaz)
	timer:sleep(800),
	io:format("Whether double is unlocked after \"Ext: finished\"~n"),
	{[], empty, empty} = locker:dump(double),
	io:format("=== 8. Locker state: ===~n~s===~n", [locker:state_screen()]),
	% Test 1 of :lend/2
	LockltlendertermLender = fun(T) -> spawn_link(fun() ->
			ok = locker:lock(T),
			locker:lend(T, Self),
			ok = locker:lock(T),
			timer:sleep(100),
			ok = locker:unlock(T),
			ok = locker:unlock(T),
			ok = locker:unlock(T),
			fail = locker:unlock(T)
		end)
	end,
	LTLenderPid = LockltlendertermLender(ltlenderterm),
	io:format("Self=~p, Pid=~p~n", [Self, LTLenderPid]),
	ok = locker:lock(ltlenderterm),
	ok = locker:unlock(ltlenderterm),
	true = locker:islocked(ltlenderterm),
	ok = locker:lend(ltlenderterm, LTLenderPid),
	false = locker:islocked(ltlenderterm),
	timer:sleep(500),
	true = locker:islocked(ltlenderterm),
	ok = locker:unlock(ltlenderterm),
	io:format("=== 9. Locker state: ===~n~s===~n", [locker:state_screen()]),
	% Test 2 of :lend/2
	ok = locker:lock(translock),
	OtherProc = spawn_link(fun() ->
			timer:sleep(250),
			ok = locker:unlock(translock),
			Self ! {self(), translock, unlocked}
			end),
	ok = locker:lend(translock, OtherProc),
	ok = receive
			{OtherProc, translock, unlocked} -> ok
		after 500 ->
			io:format("Can't unlock in other proc~n"),
			fail
		end,
	ok = locker:unlock(translock),
	fail = locker:unlock(translock),
	% Test 3 of :lend/2
	ok = locker:lock(tlock2),
	OtherProc2 = spawn_link(fun() -> locker:lock(tlock2),
					timer:sleep(500),
					Self ! {self(), tlock2, unlocked}
					end),
	ok = locker:lend(tlock2, OtherProc2),
	ok = locker:lock(tlock2),
	ok = receive {OtherProc2, tlock2, unlocked} -> ok end,
	ok = locker:unlock(tlock2),
	ok = locker:unlock(tlock2),
	io:format("Locker performance test:~n"),
	perftest:comprehensive(100000, fun() ->
			ok = locker:lock(perflock),
			ok = locker:unlock(perflock)
		end),
	io:format("10. Locker state:~n~s", [locker:state_screen()]),
	ok = locker:unlock(lockedElsewhere),
	{[_], Self, _} = locker:dump(baz),
	ok = locker:unlock(baz),	% for trylock (Bbaz)
	{[_], Self, _} = locker:dump(baz),
	ok = locker:unlock(baz),	% for plain lock (Abaz)
	{[], empty, empty} = locker:dump(baz),
	io:format("11. Locker state:~n~s", [locker:state_screen()]),
	ok = locker:lock(distDU),
	{[_], Self, _} = locker:dump(distDU),
	P2 = spawn_link(fun() ->
			Me = self(),
			{[_], Self, _} = locker:dump(distDU),
			locker:lock(distDU),
			{[_], Me, _} = locker:dump(distDU),
			receive unlock -> ok end,
			{[_], Me, _} = locker:dump(distDU),
			locker:unlock(distDU),
			{[], empty, empty} = locker:dump(distDU),
			receive finish -> go end
		end),
	timer:sleep(100),
	io:format("12. Locker state:~n~s", [locker:state_screen()]),
	{[_], Self, _} = locker:dump(distDU),
	ok = locker:unlock(distDU),
	{[_], P2, _} = locker:dump(distDU),
	fail = locker:unlock(distDU),
	{[_], P2, _} = locker:dump(distDU),
	P2 ! unlock,
	timer:sleep(100),
	{[], empty, empty} = locker:dump(distDU),
	[] = locker:dump(pid, P),
	[] = locker:dump(pid, P2),
	[] = locker:dump(pid, Self),
	P2 ! finish,
	io:format("13. Locker state (Self=~p, P2=~p):~n~s",
		[Self, P2, locker:state_screen()]),
	ok = locker:lock(distDU),
	[{Self, distDU}] = locker:dump(pid, Self),
	ok = locker:lock(second),
	[{Self, distDU}, {Self, second}] = locker:dump(pid, Self),
	P3 = spawn(fun() ->
			{[_], Self, _} = locker:dump(distDU),
			locker:lock(first),
			locker:lock(distDU),
			locker:lock(second),
			locker:lock(third)
		end),
	timer:sleep(100),
	io:format("14. Locker state (Self=~p, P3=~p):~n~s",
		[Self, P3, locker:state_screen()]),
	[{Self, distDU}, {Self, second}] = locker:dump(pid, Self),
	[{P3, first}, {P3, distDU}] = locker:dump(pid, P3),
	{[_], Self, _} = locker:dump(distDU),
	erlang:exit(P3, crashed),
	ok = locker:unlock(second),
	fail = locker:unlock(second),
	ok = locker:unlock(distDU),
	fail = locker:unlock(distDU),
	[] = locker:dump(pid, Self),
	timer:sleep(100),
	{[], empty, empty} = locker:dump(first),
	false = is_process_alive(P3),
	{[], empty, empty} = locker:dump(distDU),
	{[], empty, empty} = locker:dump(second),
	{[], empty, empty} = locker:dump(third),
	[] = locker:dump(pid, P3),
	io:format("Locker autotesting finished~n"),
	ok.

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

