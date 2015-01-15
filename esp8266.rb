#!/usr/bin/env ruby
#encoding: UTF-8

require 'serialport'
require 'io/wait'
require 'thread'
require 'pp'
require 'colorize'
require 'pi_piper'
require 'csv'

include PiPiper

class IO
  def ready_for_read?
    result = IO.select([self], nil, nil, 0)
    result && (result.first.first == self)
  end
end


class Esp8266
  attr_accessor :sq,:c_state,:port
  Holdoff=0.3
  MODE=1
  MUX=1
#AT+CIPSERVER=1,8888
  @@Commands={
    reboot:  {ok: "ready", tout:4000,holdoff:4},
    init:    {holdoff:2},
    ping:    {at: "", tout:200, period: 120, retries:4},
    reset:   {at: "+RST", ok: "ready", tout:4000, hold: 1,holdoff:5},
    cwmode?: {at: "+CWMODE?", tout:500, period: 10},
    cwmode:  {at: "+CWMODE=", args:1, tout:500, ok: ["OK","no change"]},
    cipmux?: {at: "+CIPMUX?", tout:500, period: 10},
    cipmux:  {at: "+CIPMUX=", args:1, tout:500},
    cwsap:   {at: "+CWSAP=", args:1, tout:500, modes:2},
    aplist:  {at: "+CWLAP", period: 60, tout:5000, modes:1},
    joined:  {at: "+CWLIF", period: 60, tout:5000, modes:2},
    join:    {at: "+CWJAP=", args:2, tout:5000, modes:1},
    unjoin:  {at: "+CWQAP", tout:500},
    join?:   {at: "+CWJAP?", tout:500, period: 60, modes:1},
    ip?:     {at: "+CIFSR", tout:500, period: 20},
    cips:    {at: "+CIPSTATUS", tout:500, period: 10},
    connect: {at: "+CIPSTART=", args: 1, tout:2000, modes:1},
    server:  {at: "+CIPSERVER=", args: 1, tout:2000},
    send:    {at: "+CIPSEND=", args: 1, has_data:true, tout:2000, modes:1, ok: "SEND OK"},
    baud:    {at: "+CIOBAUD=", args: 1, tout:500},
  }

def initialize(hash={})

    @debug=hash[:debug]
    newstate :idle
    @c_last=nil
    @c_state=:idle
    @c_state_s=stamp
    @c_stamps={}
    @holdoff=Holdoff

    @ap_list=[]

    @clients=[]

    @out_q=Queue.new
    @in_q=Queue.new
    @out_q << {ip: "20.20.20.21",port:8099,proto:"UDP",data: "kuukkuu"}
    @out_q << {ip: "20.20.20.21",port:8099,proto:"UDP",data: "kuukkuu2"}

    @sq=Queue.new
    #@sq << {cmd: :reboot}
    @sq << {cmd: :init}
    @sq << {cmd: :ping}
    @sq << {cmd: :cwmode, args:"#{MODE}"}
    @sq << {cmd: :cwmode?}
    #@sq << {cmd: :baud, args: "9600"}
    @sq << {cmd: :ping}
    @sq << {cmd: :ping}
    @sq << {cmd: :cwsap, args: "\"TIKKU\",\"\",3,"}
    #@sq << {cmd: :ping}
    #@sq << {cmd: :reset}
    #@sq << {cmd: :aplist}
    #@sq << {cmd: :cips}
    @lbuf=""
    hash[:reset] = 18 if not hash[:reset]
    @reset =PiPiper::Pin.new(:pin => hash[:reset], :direction => :out)
    @reset.on
    #@ch_pd =PiPiper::Pin.new(:pin => hash[:pd], :direction => :out)

    if not hash[:dev]
      puts "Error: No serial Device??"
      return nil
    end
    if not File.chardev? hash[:dev]
      puts "Error: '#{hash[:dev]}'' is not serial Device??"
      return nil
    end
    begin
      @port = SerialPort.new hash[:dev],115200,8,1,SerialPort::NONE
      #$sp.read_timeout = 100
      @port.flow_control= SerialPort::NONE
      @port.binmode
      @port.sync = true
    rescue => e
      puts "Error: Cannot open serial device: #{e}"
      pp e.backtrace
      return nil
    end
    @dev=hash[:dev]
    puts "Open Serial OK!" if @debug
    @taski_poll=Thread.new do
      loop do
        now=stamp
        if @c_state==:idle
          if now-@c_state_s>@holdoff #holdoff
            if not @sq.empty?
              act=@sq.pop
              #print "::#{act}\r\n"
              cmd act
            else # queue empty, check for periodicals
              runit=false
              @@Commands.each do |c,d|
                if d[:period]==:once
                  if not @c_stamps[c]
                    runit=true
                  end
                elsif d[:period]
                  if not @c_stamps[c] or now-@c_stamps[c]>d[:period]*1000
                    runit=true
                  end
                end
                if runit
                  cmd({cmd: c})
                  break #just one ;)
                end
              end
            end
          end
        else #in command -- check timeout
          if now-@c_state_s>@c_tout
            puts "\nError: Command #{@c_last} timeouted (#{@c_tout})-- retry? -- reboot?".colorize(:red).bold
            newc_state :idle
          end
        end
        sleep 0.001
      end
    end

    while @port.ready_for_read?
      ch = @port.readbyte
    end

    @taski_in=Thread.new do
      loop do
        while @port.ready_for_read?
          begin
            ch = @port.readbyte
            if ch.chr=="\r"
              #print "\r\nROW:[#{@lbuf}]\r\n"
              if @lbuf!=""
                print "\n"
                parse_reply @lbuf
              end
              @lbuf=""
            elsif ch.chr=="\n"
              #ignore
            else
              @lbuf+=ch.chr
              if @c_state==:idle
                print ch.chr.colorize(:magenta)
              else
                print ch.chr.colorize(:red)
              end
              if @lbuf=="> " and @c_last[:cmd]==:send
                @port.write "#{@sendbuf}\n"
              end
            end
          rescue => e
            puts "Error: In task fails: #{e} #{act}"
            pp e.backtrace
            return nil
          end
        end
        sleep 0.001
      end
    end
  end

  def stamp
    (Time.now.to_f*1000).to_i #ms counter
  end

  def newstate n
    now=stamp
    if @state==n
      puts "Warning: Re-enter #{n}"
    end
    #puts "Debug: From '#{@state}' To '#{n}' after #{now-(@state_s||stamp)}ms".colorize(:yellow)
    @state=n
    @state_s=now
  end

  def cmd act
    begin
      @holdoff=(@@Commands[act[:cmd]][:holdoff]||Holdoff)*1000.0 if @@Commands[act[:cmd]]
      if act[:cmd]==:raw #for raw send , debug console etc.
        puts "Debug: sent '#{act[:str]}'".colorize(:yellow)
        @port.write "#{act[:str]}\r\n"
      elsif act[:cmd]==:aps
        @ap_list.each_with_index do |data,i|
          printf "%2d: %s\n",i,"#{data}"
        end
      elsif act[:cmd]==:init
        puts "\nDebug: Init --------------------------------------------".colorize(:blue)
        newc_state :idle
        @port.write "\r\n" #flush any crap on serial line
        @c_stamps[act[:cmd]]=stamp+10000.0
      elsif @@Commands[act[:cmd]]
        modes=@@Commands[act[:cmd]][:modes]||3
        if ((@cwmode & modes) == 0)
          @c_stamps[act[:cmd]]=stamp+10000.0
          return
        end
        newc_state :incmd
        str=""
        if @@Commands[act[:cmd]][:at]
          str="AT#{@@Commands[act[:cmd]][:at]}"
          if @@Commands[act[:cmd]][:args]
            if @@Commands[act[:cmd]][:has_data]
              act[:args]+="\n" #nice on nc
              len=act[:args].length
              str+="1,#{len}"
              @sendbuf=act[:args]
            else
              str+=act[:args]
            end
          end

        end
        if act[:cmd]==:baud
          @port.baud=act[:args].to_i
        end
        if act[:cmd]==:reboot
          reboot
        end
        @c_stamps[act[:cmd]]=stamp
        @c_last=act
        @c_at=str
        @c_tout=@@Commands[act[:cmd]][:tout]||1000
        @c_callback=@@Commands[act[:cmd]][:callback]
        @c_ok=@@Commands[act[:cmd]][:ok]||"OK"
        @c_error=@@Commands[act[:cmd]][:error]||"ERROR"
        puts "\ncmd #{act} -> <#{str}>  ok: #{@c_ok} tout:#{@c_tout} #{@cwmode} & #{modes}".colorize(:blue).bold
        @port.write "#{str}\r\n" if str!=""
      else
        puts "Error: Unsupported command: #{act}"
      end
    rescue => e
      puts "Error: Command fails: #{e} #{act}"
      pp e.backtrace
      return nil
    end
  end

  def newc_state n
    now=stamp
    if @c_state==n
      puts "Warning: Re-enter c_state #{n}"
    end
    #puts "Debug: C From '#{@c_state}' To '#{n}' after #{now-(@c_state_s||stamp)}ms".colorize(:yellow)
    @c_state=n
    @c_state_s=now
    @c_reply=[]
  end

  def cb_cwmode?
    #+CWMODE:1
    if @c_reply[0][/\+CWMODE:(\d+)/]
      @cwmode=$1.to_i
      if @cwmode!=MODE
        sq << {cmd: :cwmode, args:"#{MODE}"}
        sq << {cmd: :cwmode?}
      end
    end
  end

  def cb_cipmux?
    #+CWMODE:1
    if @c_reply[0][/\+CIPMUX:(\d+)/]
      @cipmux=$1.to_i
      if @cipmux!=MUX
        sq << {cmd: :cipmux, args:"#{MUX}"}
        sq << {cmd: :cipmux?}
      end
    end
  end


  def cb_connect
    f=CSV.parse(@c_last[:args])
    if f[0]
      data=f[0]
      i=data[0].to_i
      obj={proto: data[1],ip:data[2],port:data[3], dir: 0, state: :open, tick:0}
      @clients[i]=obj
      puts "******************** Opened #{obj}".colorize(color: :yellow,background: :black).bold
      pp @clients
    end
  end

  def cb_cips
    begin
      if @c_reply[0][/STATUS:(\d+)/]
        case $1.to_i
        when 2
          @cipstatus=:got_ip
        when 3
          @cipstatus=:connected
        when 4
          @cipstatus=:disconnected
        when 5
          @cipstatus=:busy
        else
          @cipstatus=nil
        end
        @cipstatus_s=stamp
        puts "cipstatus: '#{@cipstatus}'"
      else
        puts "cippi: #{@c_reply} ???"
      end
      #+CIPSTATUS:0,"UDP","20.20.20.21",8099,0
      if @c_reply[1]
        @c_reply[1..-1].each do |con|
          if con[/\+CIPSTATUS:(\d+),"(.+)","(.+)",(\d+),(\d+)/]
            puts "Connection: #{$1},#{$2},#{$3},#{$4},#{$5}"
            i=$1.to_i
            obj={proto: $2,ip:$3,port:$4, dir: $5.to_i, state: :open}
            if not @clients[i]
              @clients[i]=obj.merge({tick: 1})
            elsif @clients[i][:ip]==obj[:ip] and @clients[i][:port]==obj[:port] and @clients[i][:proto]==obj[:proto] and @clients[i][:dir]==obj[:dir]
              @clients[i][:tick]+=1
              @clients[i][:state]=:open
            else # connection has changed!
              @clients[i]=obj.merge({tick: 1})
            end
          end
        end
        pp @clients
      end
      if @clients==[]
        puts "NO CONNECTIONS -- LET'S CONNECT!"
        sq << {cmd: :connect, args:"1,\"UDP\",\"20.20.20.21\",8099"}
        sq << {cmd: :connect, args:"2,\"UDP\",\"20.20.20.21\",8098"}
        sq << {cmd: :cips}
        #sq << {cmd: :server, args: "1,9999"}
      end
    rescue => e
      puts "Error: cb_cips fails: #{e} "
      pp e.backtrace
      return nil
    end
  end


  #AT+CIPSTART="UDP","20.20.20.21",8099
  def cb_aplist #we have completed an command and got this as reply:
    @c_reply.each do |ap|
      if ap[/\+CWLAP:\((.+)\)/]
        f=CSV.parse($1)
        if f[0]
          data=f[0]
          ssid=data[1]
          obj={
              security: data[0].to_i,
              ssid: ssid,
              signal: data[2].to_i,
              mac: data[3],
              channel: data[4].to_i,
              stamp: stamp,
            }
          done=false
          @ap_list.each_with_index do |ap,i|
            if ap[:ssid]==ssid
              @ap_list[i]=@ap_list[i].merge obj
              @ap_list[i][:found_count]+=1
              done=true
            end
          end
          if not done
            @ap_list<<obj.merge({
              join_last: 0.0,
              join_last_error: nil,
              join_count: 0,
              join_secs: 0,
              found_count: 1,
              })
          end
        end
      end
    end
    #pp @ap_list
  end

  def cb_join?
    puts "JOINED OK! -- let's check connection!"
  end

  def err_join?
    puts "NOT JOINED! -- let's join!"
    sq << {cmd: :join, args:"\"HALLI\",\"\""}
    sq << {cmd: :join?}
  end

  def parse_reply s
    now=stamp
    if @c_state==:incmd
      if (@c_ok.is_a? String and s==@c_ok) or (@c_ok.include? s)
        cb="cb_#{@c_last[:cmd]}".to_sym
        puts ">Ok detected! #{@c_last}, took  #{now-@c_state_s}ms , tout #{@c_tout}ms cb:#{cb}".colorize(:green)
        if @c_reply[0]==@c_at
          @c_reply=@c_reply[1..-1]
        else
          puts "title missin!!!!!!!!!!!!++++??????????????++"
        end

        begin
          send cb
        rescue =>e
          #puts "cb fail #{e}"
        end
        newc_state :idle
      elsif s==@c_error
        cb="err_#{@c_last[:cmd]}".to_sym
        puts ">Error detected! #{@c_last}, took  #{now-@c_state_s}ms , tout #{@c_tout}ms cb:#{cb}".colorize(:red)
        begin
          send cb
        rescue =>e
          #puts "cb fail #{e}"
        end
        newc_state=:idle
      else #its data, collect it!
        @c_reply << s
      end
    end
  end

  def reboot
    puts "Debug: Hard Rebooting ".colorize(:red).bold
    @reset.off
    sleep 0.1
    @reset.on
  end



end

$stdout.sync = true
options={dev: "/dev/ttyAMA0", debug: true}
$dev=Esp8266.new options

port=$dev.port
#:join "winttitonttu",""
loop  do
  if $stdin.ready?
    c = $stdin.gets.chop
    puts "got #{c} , #{$dev.c_state}"
    if c[/^\:(.+) (.+)$/]
      puts "<#{$1}> <#{$2}>"
      $dev.sq << {cmd: $1.to_sym, args: $2}
    elsif c[/^\:(.+)$/]
      $dev.sq << {cmd: $1.to_sym, args: $2}
    else
      $dev.sq << {cmd: :raw, str:c}
    end
  else
    sleep 0.01
  end
end
