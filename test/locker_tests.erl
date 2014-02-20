-module(locker_tests).

-include_lib("eunit/include/eunit.hrl").

locker_self_test_() ->
    {setup,
     fun () -> {ok, Pid} = locker:start_link(), Pid end,
     fun (_) -> gen_server:cast(locker, stop) end,
     [{"locker_basictest", fun locker_basictest/0},
      {"locker_selftest1", fun locker_selftest1/0},
      {"locker_selftest2", fun locker_selftest2/0}]
    }.

locker_basictest() ->
    ?assertEqual(ok, locker:lock(one)),
    ?assertEqual(ok, locker:lock(two)),
    ?assertEqual(true,  locker:islocked(one)),
    ?assertEqual(true,  locker:islocked(two)),
    ?assertEqual(false, locker:islocked(three)),
    ?assertEqual(false, run_in_other_proc(fun() -> locker:islocked(one) end)),
    ?assertEqual(false, run_in_other_proc(fun() -> locker:islocked(two) end)),
    ?assertEqual(false, run_in_other_proc(fun() -> locker:islocked(three) end)),
    ?assertEqual(fail,  run_in_other_proc(fun() -> locker:trylock(one) end)),
    ?assertEqual(fail,  run_in_other_proc(fun() -> locker:trylock(two) end)),
    ?assertEqual(ok,    run_in_other_proc(fun() -> locker:trylock(three) end)),
    ?assertEqual(true,  locker:islocked(one)),
    ?assertEqual(true,  locker:islocked(two)),
    ?assertEqual(false, locker:islocked(three)),
    ?assertEqual(ok,    locker:unlock(one)),
    ?assertEqual(ok,    locker:unlock(two)),
    ?assertEqual(fail,  locker:unlock(three)),
    ?assertEqual(false, locker:islocked(one)),
    ?assertEqual(false, locker:islocked(two)),
    ?assertEqual(false, locker:islocked(three)),
    ok.
    
run_in_other_proc(Fun) when is_function(Fun, 0) ->
    Ref = make_ref(),
    Self = self(),
    spawn(fun() -> Self ! {Ref, Fun()} end),
    receive 
        {Ref, Msg} ->
            Msg
    after 500 ->
        no_msg
    end.


locker_selftest1() ->
    %% Autotesting  
    Self = self(),
    ?assertEqual(ok, locker:lock(again)),
    ?assertEqual(ok, locker:lock(again)),    % Same process!),
    %% 1. Locker state:
    ?assertEqual(ok, locker:unlock(again)),
    %% 2. Locker state:
    ?assertEqual(ok, locker:unlock(again)),    % Second unlocking is OK,
    ?assertEqual(fail, locker:unlock(again)),        % Unlock second time? No.
    ?assertEqual(ok, locker:lock(foo)),
    ?assertEqual(ok, locker:lock(bar)),
    ?assertEqual(fail, locker:unlock(nothing)),
    ?assertEqual(ok, locker:trylock(foo)),
    ?assertEqual(ok, locker:trylock(bar)),
    ?assertEqual(ok, locker:trylock(baz)),
    ?assertEqual(ok, locker:unlock(baz)),
    %% === 3. Locker state: ======~n
    ?assertEqual(ok, locker:lock(double)),
    %% === 4. Locker state: ======~n
    PPid = self(),
    P = spawn_link(fun () ->
        %% Ext: spawned , parent 
        PPid ! {spawned, self()},
        %% Ext: double locking...
        ?assertEqual(ok, locker:lock(double)),
        %% Ext: double unlocked
        receive unlocked -> ok end,
        %% Ext: L(lockedElsewhere)
        ?assertEqual(ok, locker:lock(lockedElsewhere)),
        ?assertEqual(fail, locker:trylock(foo)),
        ?assertEqual(ok, locker:lock(baz)),
        %% Ext: done
        PPid ! {done, self()},
            receive finish -> ok end,
        timer:sleep(100)
    end),
    receive {spawned, P} -> ok end,
    timer:sleep(100),
    %% === 5. Locker state: ======~n
    ?assertEqual(ok, locker:unlock(double)),
    ?assertMatch({[_], _, _}, locker:dump(double)),
    P ! unlocked,
    ?assertMatch({[_], _, _}, locker:dump(double)),
    %% === 6. Locker state: ======~n
    %% Locker: waiting for external  to initialize
    receive {done, P} -> ok end, %% Locker: external initialized
    %% === 7. Locker state: ======~n
    ?assertEqual(ok, locker:unlock(foo)),
    ?assertEqual(ok, locker:unlock(bar)),
    ?assertEqual(ok, locker:unlock(foo)),
    ?assertEqual(ok, locker:unlock(bar)),
    ?assertEqual(fail, locker:unlock(bar)),
    ?assertEqual(fail, locker:trylock(lockedElsewhere)),
    ?assertEqual(false, locker:islocked(lockedElsewhere)),
    ?assertEqual(fail, locker:trylock(baz)),
    %% Locker: waiting for external  to finish
    P ! finish,
    ?assertEqual(fail, locker:trylock(baz)),
    %% Trying to lock something belonging to external process
    ?assertEqual(ok, locker:lock(lockedElsewhere)),
    ?assertEqual(ok, locker:lock(baz)),
    ?assertEqual(ok, locker:trylock(baz)),    % (Abaz),
    ?assertMatch(true, locker:islocked(baz)),    % (Bbaz)
    timer:sleep(100),
    %% Whether double is unlocked after
    ?assertMatch({[], empty, empty}, locker:dump(double)),
    % Test 1 of :lend/2
    LockltlendertermLender = fun(T) -> spawn_link(fun() ->
            ?assertEqual(ok, locker:lock(T)),
            locker:lend(T, Self),
            ?assertEqual(ok, locker:lock(T)),
            timer:sleep(100),
            ?assertEqual(ok, locker:unlock(T)),
            ?assertEqual(ok, locker:unlock(T)),
            ?assertEqual(ok, locker:unlock(T)),
            fail = locker:unlock(T)
        end)
    end,
    LTLenderPid = LockltlendertermLender(ltlenderterm),
    ?assertEqual(ok, locker:lock(ltlenderterm)),
    ?assertEqual(ok, locker:unlock(ltlenderterm)),
    ?assertEqual(true, locker:islocked(ltlenderterm)),
    ?assertEqual(ok, locker:lend(ltlenderterm, LTLenderPid)),
    ?assertEqual(false, locker:islocked(ltlenderterm)),
    timer:sleep(500),
    true = locker:islocked(ltlenderterm),
    ?assertEqual(ok, locker:unlock(ltlenderterm)),
    [] = locker:dump(pid, P),
    ok.


locker_selftest2() ->
    % Test 2 of :lend/2
    Self = self(),
    ?assertEqual(ok, locker:lock(translock)),
    OtherProc = spawn_link(fun() ->
                    timer:sleep(250),
                    ?assertEqual(ok, locker:unlock(translock)),
                    Self ! {self(), translock, unlocked}
            end),
    ?assertEqual(ok, locker:lend(translock, OtherProc)),
    ?assertEqual(ok, 
        receive
            {OtherProc, translock, unlocked} -> ok
        after 500 ->
                %% Can't unlock in other proc
                fail
        end),
    ?assertEqual(ok, locker:unlock(translock)),
    ?assertEqual(fail, locker:unlock(translock)),
    % Test 3 of :lend/2
    ?assertEqual(ok, locker:lock(tlock2)),
    OtherProc2 = spawn_link(fun() -> locker:lock(tlock2),
                    timer:sleep(500),
                    Self ! {self(), tlock2, unlocked}
            end),
    ?assertEqual(ok, locker:lend(tlock2, OtherProc2)),
    ?assertEqual(ok, locker:lock(tlock2)),
    ?assertEqual(ok, receive {OtherProc2, tlock2, unlocked} -> ok end),
    ?assertEqual(ok, locker:unlock(tlock2)),
    ?assertEqual(ok, locker:unlock(tlock2)),
    %% 10. Locker state
    ?assertEqual(ok, locker:unlock(lockedElsewhere)),
    {[_], Self, _} = locker:dump(baz),
    ?assertEqual(ok, locker:unlock(baz)),    % for trylock (Bbaz)),
    {[_], Self, _} = locker:dump(baz),
    ?assertEqual(ok, locker:unlock(baz)),    % for plain lock (Abaz)),
    {[], empty, empty} = locker:dump(baz),
    %% 11. Locker stat:
    ?assertEqual(ok, locker:lock(distDU)),
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
    %% 12. Locker state
    {[_], Self, _} = locker:dump(distDU),
    ?assertEqual(ok, locker:unlock(distDU)),
    {[_], P2, _} = locker:dump(distDU),
    ?assertEqual(fail, locker:unlock(distDU)),
    {[_], P2, _} = locker:dump(distDU),
    P2 ! unlock,
    timer:sleep(100),
    {[], empty, empty} = locker:dump(distDU),
    [] = locker:dump(pid, P2),
    [] = locker:dump(pid, Self),
    P2 ! finish,
    %% 13. Locker state
    ?assertEqual(ok, locker:lock(distDU)),
    [{Self, distDU}] = locker:dump(pid, Self),
    ?assertEqual(ok, locker:lock(second)),
    [{Self, distDU}, {Self, second}] = locker:dump(pid, Self),
    P3 = spawn(fun() ->
                    {[_], Self, _} = locker:dump(distDU),
                    locker:lock(first),
                    locker:lock(distDU),
                    locker:lock(second),
                    locker:lock(third)
            end),
    timer:sleep(100),
    %% 14. Locker state
    [{Self, distDU}, {Self, second}] = locker:dump(pid, Self),
    [{P3, first}, {P3, distDU}] = locker:dump(pid, P3),
    {[_], Self, _} = locker:dump(distDU),
    erlang:exit(P3, crashed),
    ?assertEqual(ok, locker:unlock(second)),
    ?assertEqual(fail, locker:unlock(second)),
    ?assertEqual(ok, locker:unlock(distDU)),
    ?assertEqual(fail, locker:unlock(distDU)),
    [] = locker:dump(pid, Self),
    timer:sleep(100),
    {[], empty, empty} = locker:dump(first),
    ?assertEqual(false, is_process_alive(P3)),
    {[], empty, empty} = locker:dump(distDU),
    {[], empty, empty} = locker:dump(second),
    {[], empty, empty} = locker:dump(third),
    [] = locker:dump(pid, P3),
    %% Locker autotesting finished
    ok.

