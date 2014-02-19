-module(locker_tests).

-include_lib("eunit/include/eunit.hrl").

locker_self_test() ->
    {setup,
     fun locker:start_link/0,
     fun (_) -> exit(whereis(locker), normal) end,
     [{"locker_selftest", fun locker_selftest/0}]
    }.


locker_selftest() ->
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

