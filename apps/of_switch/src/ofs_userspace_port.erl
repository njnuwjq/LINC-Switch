%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc Module to manage sending and receiving data from port.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofs_userspace_port).

-behaviour(gen_server).

%% API
-export([start_link/1,
         send/2,
         change_config/2,
         stop/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include("of_switch.hrl").
-include("of_switch_userspace.hrl").

-record(state, {port :: port(),
                socket :: integer(),
                ofs_port_num :: integer(),
                interface :: string()}).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

-spec start_link(list(tuple())) -> {ok, pid()} | ignore | {error, term()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

-spec send(integer(), #ofs_pkt{}) -> ok.
send(OutPort, OFSPkt) ->
    case ets:lookup(ofs_ports, OutPort) of
        [] ->
            ?ERROR("Port ~p does not exist", [OutPort]);
        [#ofs_port{handle = Pid, config = Config}] ->
            case lists:member(no_fwd, Config) of
                true ->
                    ?WARNING("Forwarding to port ~p disabled", [OutPort]);
                false ->
                    gen_server:call(Pid, {send, OFSPkt})
            end
    end.

-spec change_config(integer(), #port_mod{}) ->
        {error, bad_port | bad_hw_addr} | ok.
change_config(PortId, PortMod) ->
    case ets:lookup(ofs_ports, PortId) of
        [] ->
            {error, bad_port};
        %% TODO: [#ofs_port{hw_addr = OtherHWAddr}] ->
        %%           {error, bad_hw_addr};
        [#ofs_port{handle = Pid}] ->
            gen_server:cast(Pid, {change_config, PortMod})
    end.

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:cast(Pid, stop).

%%%-----------------------------------------------------------------------------
%%% gen_server callbacks
%%%-----------------------------------------------------------------------------

-spec init(list(tuple())) -> {ok, #state{}} |
                             {ok, #state{}, timeout()} |
                             ignore |
                             {stop, Reason :: term()}.
init(Args) ->
    %% epcap crashes if this dir does not exist.
    filelib:ensure_dir(filename:join([code:priv_dir(epcap), "tmp", "ensure"])),
    {interface, Interface} = lists:keyfind(interface, 1, Args),
    {ofs_port_num, OfsPortNum} = lists:keyfind(ofs_port_num, 1, Args),
    lager:info("Creating port: ~p", [Args]),
    State = case re:run(Interface, "tap*", [{capture, none}]) of
                match ->
                    {ip, IP} = lists:keyfind(ip, 1, Args),
                    {ok, Ref} = tuncer:create(Interface),
                    ok = tuncer:up(Ref, IP),
                    Fd = tuncer:getfd(Ref),
                    Port = open_port({fd, Fd, Fd}, [binary]),
                    #state{port = Port, ofs_port_num = OfsPortNum};
                nomatch ->
                    epcap:start([{promiscous, true}, {interface, Interface}]),
                    {ok, Socket, _Length} = bpf:open(Interface),
                    bpf:ctl(Socket, setif, Interface),
                    #state{socket = Socket, ofs_port_num = OfsPortNum}
            end,
    OfsPort = #ofs_port{number = OfsPortNum,
                        type = physical,
                        handle = self()
                       },
    ets:insert(ofs_ports, OfsPort),
    ets:insert(ofs_port_counters,
               #ofs_port_counter{number = OfsPortNum}),
    {ok, State#state{interface = Interface,
                     ofs_port_num = OfsPortNum}}.

-spec handle_call(Request :: term(), From :: {pid(), Tag :: term()},
                  #state{}) ->
                         {reply, Reply :: term(), #state{}} |
                         {reply, Reply :: term(), #state{}, timeout()} |
                         {noreply, #state{}} |
                         {noreply, #state{}, timeout()} |
                         {stop, Reason :: term() , Reply :: term(), #state{}} |
                         {stop, Reason :: term(), #state{}}.
handle_call({send, OFSPkt}, _From, #state{socket = Socket,
                                          port = undefined,
                                          ofs_port_num = OutPort} = State) ->
    Frame = pkt:encapsulate(OFSPkt#ofs_pkt.packet),
    lager:info("OutSocket InPort: ~p, OutPort: ~p", [OFSPkt#ofs_pkt.in_port, OutPort]),
    procket:write(Socket, Frame),
    update_port_transmitted_counters(OutPort, byte_size(Frame)),
    {reply, ok, State};
handle_call({send, OFSPkt}, _From, #state{socket = undefined,
                                          port = ErlangPort,
                                          ofs_port_num = OutPort} = State) ->
    Frame = pkt:encapsulate(OFSPkt#ofs_pkt.packet),
    lager:info("OutPort InPort: ~p, OutPort: ~p", [OFSPkt#ofs_pkt.in_port, OutPort]),
    port_command(ErlangPort, Frame),
    update_port_transmitted_counters(OutPort, byte_size(Frame)),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(Msg :: term(),
                  #state{}) -> {noreply, #state{}} |
                               {noreply, #state{}, timeout()} |
                               {stop, Reason :: term(), #state{}}.
handle_cast({change_config, #port_mod{}}, State) ->
    %% FIXME: implement
    {noreply, State};
handle_cast(stop, State) ->
    {stop, shutdown, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(Info :: term(),
                  #state{}) -> {noreply, #state{}} |
                               {noreply, #state{}, timeout()} |
                               {stop, Reason :: term(), #state{}}.
handle_info({packet, _DataLinkType, _Time, _Length, Frame},
            #state{ofs_port_num = OfsPortNum} = State) ->
    handle_frame(Frame, OfsPortNum),
    {noreply, State};
handle_info({Port, {data, Frame}}, #state{ofs_port_num = OfsPortNum,
                                          port = Port} = State) ->
    handle_frame(Frame, OfsPortNum),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(Reason :: term(), #state{}) -> none().
terminate(_Reason, _State) ->
    ok.

-spec code_change(Vsn :: term() | {down, Vsn :: term()},
                  #state{}, Extra :: term()) ->
                         {ok, #state{}} |
                         {error, Reason :: term()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%-----------------------------------------------------------------------------
%%% Internal functions
%%%-----------------------------------------------------------------------------

handle_frame(Frame, OfsPortNum) ->
    Packet = pkt:decapsulate(Frame),
    OFSPacket = of_switch_userspace:pkt_to_ofs(Packet, OfsPortNum),
    update_port_received_counters(OfsPortNum, byte_size(Frame)),
    of_switch_userspace:route(OFSPacket).

-spec update_port_received_counters(integer(), integer()) -> any().
update_port_received_counters(PortNum, Bytes) ->
    ets:update_counter(ofs_port_counters, PortNum,
                       [{#ofs_port_counter.received_packets, 1},
                        {#ofs_port_counter.received_bytes, Bytes}]).

-spec update_port_transmitted_counters(integer(), integer()) -> any().
update_port_transmitted_counters(PortNum, Bytes) ->
    ets:update_counter(ofs_port_counters, PortNum,
                       [{#ofs_port_counter.transmitted_packets, 1},
                        {#ofs_port_counter.transmitted_bytes, Bytes}]).
