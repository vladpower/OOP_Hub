#!/usr/bin/env ruby
require 'set'

Thread.abort_on_exception=true

class Device
    attr_accessor :connect_list
    def initialize(attributes = {})
        @connect_list = []
        @name = attributes[:name]
        @thread = Thread.new() do
            while $sim_run
                select(nil,nil,nil,0.01)
                check_connections
            end
        end
    end
    def add_connection(con)
        @connect_list.push({con: con, route: Set.new()})
    end
    def send_to_con(msg,con)
        buf = con.w_buffer self
        buf.push(msg)
    end
    def send_to_addr(msg,addr)
        next_con = identify_con addr
        if next_con
            send_to_con msg, next_con[:con]
        end
    end
    def check_connections
        @connect_list.each do |con|
            buf = con[:con].r_buffer self
            buf.each do |msg|
                recv_message msg, con
            end
            buf.clear
        end
    end
    def recv_message(msg, con)
        case msg.type
            when :out_route
                out_traversal msg, con
            when :in_route
                in_traversal msg, con
            when :energy_use
                energy_sum msg, con
            when :all_off
                off_device msg
            else
                if !msg.addr.nil? && msg.addr == @addr
                    handle_message msg
                else
                    send_next msg
                end
        end
    end
    def send_next(msg)
        send_to_addr msg, msg.addr
    end
    def out_traversal(msg, con)
        if !con[:route].include? 0
            con[:route] << 0
        end
        
        
        @connect_list.each do |c|
            if c != con
                c[:route].clear
                if @on
                    send_to_con msg, c[:con]
                end
            end
        end
        
        info = @addr
        reply_msg = Message.new(addr: 0, type: :in_route, info: info)
        send_to_con reply_msg, con[:con]
    end
    def in_traversal(msg, con)
        con[:route] << msg.info
        if @addr != 0
            send_to_addr msg, 0 #to host
        end
    end
    def energy_sum(msg, con)
        if @on
            @connect_list.each do |c|
                if c != con
                    send_to_con msg, c[:con]
                end
            end
            info = @energy_needs
            reply_msg = Message.new(addr: 0, type: :energy_plus, info: info)
            send_to_addr reply_msg, 0 #to host
        end
    end
    def identify_con(addr)
        @connect_list.each do |c|
            if c[:route].include? addr
                return c
            end
        end
        nil
    end
    def off_device(msg)
        info = {is_on: @on, energy_needs: @energy_needs, addr: @addr}
        reply_msg = Message.new(addr: 0, type: :give_energy_for_off, info: info)
        send_to_addr reply_msg, 0 #to host
        
        @connect_list.each do |con|
            if !con[:route].include? 0
                send_to_con msg, con[:con]
            end
        end
    end
    def handle_message(msg)
        case msg.type
            when :check
                info = {name: @name, is_on: @on, energy_needs: @energy_needs}
                reply_msg = Message.new(addr: 0, type: :dev_info, info: info)
                send_to_addr reply_msg, 0 #to host
            when :get_energy_for_on
                info = {is_on: @on, energy_needs: @energy_needs, addr: @addr}
                reply_msg = Message.new(addr: 0, type: :give_energy_for_on, info: info)
                send_to_addr reply_msg, 0 #to host
            when :get_energy_for_off
                msg.type = :all_off
                off_device msg
            when :on
                @on = true
                info = {name: @name}
                reply_msg = Message.new(addr: 0, type: :on_success, info: info)
                send_to_addr reply_msg, 0 #to host
            when :off
                @on = false
                info = {name: @name}
                reply_msg = Message.new(addr: 0, type: :off_success, info: info)
                send_to_addr reply_msg, 0 #to host
        end
    end
end

class Connection
    def initialize(attributes = {})
        @u_buffer = []
        @d_buffer = []
        @u_device = attributes[:u_device]
        @d_device = attributes[:d_device]
        @u_device.add_connection self
        @d_device.add_connection self
    end
    def r_buffer(device)
        if device==@u_device
            @u_buffer
        else
            @d_buffer
        end
    end
    def w_buffer(device)
        if device==@u_device
            @d_buffer
        else
            @u_buffer
        end
    end
end

class Message
    attr_accessor :addr
    attr_accessor :type
    attr_accessor :info
    def initialize(attributes = {})
        @addr = attributes[:addr]
        @type = attributes[:type]
        @info = attributes[:info]
    end
end

class Host < Device
    @@instance = nil
    def self.instance
        if @@instance.nil?
            @@instance = Host.new(name: "Host")
        else
            return @@instance
        end    
    end
    private def initialize(attributes = {})
        @energy_opportunities = 180
        @energy_needs = 50
        @energy_uses = 0
        @on = true
        @addr_num = 0
        @addr = 0
        super
    end
    def init_routes()
        msg = Message.new(type: :out_route)
        @connect_list.each do |con|
            send_to_con(msg,con[:con])
        end
    end
    def calc_energy
        @energy_uses = @energy_needs
        msg = Message.new(type: :energy_use)
        @connect_list.each do |con|
            send_to_con(msg,con[:con])
        end
    end
    def check(attributes = {})
        addr = attributes[:addr].to_i
        if addr == 0 or addr == nil
            show_dev_info @name, @on, @energy_needs
        else
            msg = Message.new(addr: addr, type: :check)
            send_to_addr msg, addr
        end
    end
    def send_on(attributes = {})
        addr = attributes[:addr].to_i
        msg = Message.new(addr: addr, type: :get_energy_for_on)
        send_to_addr msg, addr
    end
    def send_off(attributes = {})
        addr = attributes[:addr].to_i
        if addr == 0
            puts "Устройство #{@name} будет выключено!"
            $sim_run = false
        else
            msg = Message.new(addr: addr, type: :get_energy_for_off)
            send_to_addr msg, addr
        end
    end
    def send_msg(attributes = {})
        addr = attributes[:addr].to_i
        type = attributes[:type]
        info = attributes[:info]
        msg = Message.new(addr: addr, type: type, info: info)
        send_to_addr msg, addr
    end
    def handle_message(msg)
        case msg.type
            when :dev_info
                show_dev_info msg.info[:name], msg.info[:is_on], msg.info[:energy_needs]
            when :energy_plus
                @energy_uses += msg.info
                if @energy_uses > @energy_opportunities
                    puts "Не хватает энергии! #{@energy_uses}/#{@energy_opportunities}"
                    $sim_run = false
                end
            when :give_energy_for_on
                if !msg.info[:is_on]
                    energy_need = msg.info[:energy_needs]
                    addr = msg.info[:addr]
                    if energy_need <= @energy_opportunities - @energy_uses
                        reply_msg = Message.new(addr: addr, type: :on)
                        send_to_addr reply_msg, addr
                        @energy_uses += energy_need
                    else
                        puts "Не хватает энергии! #{@energy_uses}/#{@energy_opportunities}"
                        puts "Нужно #{energy_need}."
                    end
                else
                    puts "Устройство уже включено!"
                end
            when :give_energy_for_off
                if msg.info[:is_on]
                    energy_used = msg.info[:energy_needs]
                    addr = msg.info[:addr]
                    reply_msg = Message.new(addr: addr, type: :off)
                    send_to_addr reply_msg, addr #to host
                    @energy_uses -= energy_used
                end
            when :on_success
                re_route
                puts "Устройство #{msg.info[:name]} успешно включено."
            when :off_success
                re_route
                puts "Устройство #{msg.info[:name]} успешно выключено."
            when :print_success
                puts "Устройство #{msg.info[:name]} успешно напечатало страницу."
        end
    end
    def show_dev_info(name, on, energy_needs)
        puts "Название устройства: #{name}"
        puts "Состояние: #{if on then 'on' else 'off' end}"
        puts "Потребеление энергии: #{energy_needs}"
        puts "Использовано энергии в сети #{@energy_uses}/#{@energy_opportunities}"
    end
    def re_route
        if !@thread_flag
            @time = Time.now
            @thread_flag = true
            thread = Thread.new() do
                while (Time.now.sec-@time.sec) < 2
                    select(nil,nil,nil,0.1)
                end
                @time = nil
                @thread_flag = false
                init_routes()
                puts "Таблицы маршрутизации обновлены."
            end
        else
            @time = Time.now
        end
    end
    def console_processing
        user_thread = Thread.new() do
            while $sim_run
                $com = gets.chomp.split
                case $com[0]
                    when 'quit'
                        $sim_run=false
                    when 'check'
                        $host.check(addr: $com[1])
                    when 'on'
                        $host.send_on(addr: $com[1])
                    when 'off'
                        $host.send_off(addr: $com[1])
                    when 'print'
                        $host.send_msg(addr: $com[1],type: :print, info: $com[2..$com.size].join(' '))
                end
            end
        end
    end
end

class Hub < Device
    def initialize(attributes = {})
        @on = attributes[:on]
        @addr = attributes[:addr]
        @energy_needs = 8
        super
    end
end

class Terminal < Device
    def initialize(attributes = {})
        @on = attributes[:on]
        @addr = attributes[:addr]
        super
    end
    def add_connection(con)
        if @connect_list.empty?
            super
        end
    end
end

class Printer < Terminal
    def initialize(attributes = {})
        @energy_needs = 40
        super
    end
    def handle_message(msg)
        if msg.type == :print
            print_page msg
        else
            super
        end
    end
    def print_page(msg)
        puts "[#{@name}]: Печатает страницу с содержанием: \"#{msg.info}\""
        info = {name: @name}
        reply_msg = Message.new(addr: 0, type: :print_success, info: info)
        send_to_addr reply_msg, 0 #to host
    end
end

class Scaner < Terminal
    def initialize(attributes = {})
        @energy_needs = 60
        super
    end
end

class Mouse < Terminal
    def initialize(attributes = {})
        @energy_needs = 5
        super
    end
end

class Keyboard < Terminal
    def initialize(attributes = {})
        @energy_needs = 10
        super
    end
end

class Loudspeaker < Terminal
    def initialize(attributes = {})
        @energy_needs = 20
        super
    end
end

class Microphone < Terminal
    def initialize(attributes = {})
        @energy_needs = 15
        super
    end
end

class Webcam < Terminal
    def initialize(attributes = {})
        @energy_needs = 25
        super
    end
end

$sim_run = true
devices = []
connections = []

devices.push(Host.instance) #0
devices.push(Hub.new(name: "Hub 1", addr: 1, on: true)) #1
devices.push(Hub.new(name: "Hub 2", addr: 2, on: true)) #2
devices.push(Hub.new(name: "Hub 3", addr: 3, on: true)) #3
devices.push(Hub.new(name: "Hub 4", addr: 4, on: true)) #4
devices.push(Hub.new(name: "Hub 5", addr: 5, on: true)) #5
devices.push(Hub.new(name: "Hub 6", addr: 6, on: true)) #6
devices.push(Mouse.new(name: "Mouse", addr: 7, on: true)) #7
devices.push(Keyboard.new(name: "Keyboard", addr: 8, on: true)) #8
devices.push(Loudspeaker.new(name: "Loudspeaker1", addr: 9)) #9
devices.push(Loudspeaker.new(name: "Loudspeaker2", addr: 10)) #10
devices.push(Microphone.new(name: "Microphone", addr: 11)) #11
devices.push(Webcam.new(name: "Webcam", addr: 12)) #12
devices.push(Printer.new(name: "Printer", addr: 13)) #13
devices.push(Scaner.new(name: "Scaner", addr: 14)) #14

connections.push(Connection.new(u_device: devices[0],d_device: devices[1]))
connections.push(Connection.new(u_device: devices[1],d_device: devices[2]))
connections.push(Connection.new(u_device: devices[1],d_device: devices[3]))
connections.push(Connection.new(u_device: devices[2],d_device: devices[4]))
connections.push(Connection.new(u_device: devices[2],d_device: devices[5]))
connections.push(Connection.new(u_device: devices[4],d_device: devices[7]))
connections.push(Connection.new(u_device: devices[4],d_device: devices[8]))
connections.push(Connection.new(u_device: devices[5],d_device: devices[9]))
connections.push(Connection.new(u_device: devices[5],d_device: devices[10]))
connections.push(Connection.new(u_device: devices[5],d_device: devices[11]))
connections.push(Connection.new(u_device: devices[5],d_device: devices[6]))
connections.push(Connection.new(u_device: devices[6],d_device: devices[12]))
connections.push(Connection.new(u_device: devices[3],d_device: devices[13]))
connections.push(Connection.new(u_device: devices[3],d_device: devices[14]))

$host = Host.instance
$host.init_routes()
$host.calc_energy()
$host.console_processing()
while $sim_run
    
end

