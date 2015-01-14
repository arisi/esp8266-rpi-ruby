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
  attr_accessor :sq,:c_state
  Holdoff=0.3

  @@Commands={
    reboot:  {ok: "ready", tout:4000,holdoff:4},
    init:    {holdoff:2},
    ping:    {at: "", tout:200, period: 120, retries:4},
    reset:   {at: "+RST", ok: "ready", tout:4000, hold: 1,holdoff:5},
    cwmode?: {at: "+CWMODE?", tout:500, period: :once},
    cwmode:  {at: "+CWMODE=", args:1, tout:500},
    cipmux?: {at: "+CIPMUX?", tout:500, period: :once},
    cipmux:  {at: "+CIPMUX=", args:1, tout:500},
    cwsap:   {at: "+CWSAP=", args:1, tout:500},
    aplist:  {at: "+CWLAP", period: 60, tout:5000},
    joined:  {at: "+CWLIF", period: 60, tout:5000},
    join:    {at: "+CWJAP=", args:2, tout:500},
    unjoin:  {at: "+CWQAP", tout:500},
    join?:   {at: "+CWJAP?", tout:500, period: 60},
    ip?:     {at: "+CIFSR", tout:500, period: 20},
    cips:    {at: "+CIPSTATUS", tout:500, period: 10},
    baud:    {at: "+CIOBAUD=", args:1,tout:500},
  }

  def stamp
    (Time.now.to_f*1000).to_i #ms counter
  end

  def newstate n
    now=stamp
    if @state==n
      puts "Warning: Re-enter #{n}"
    end
    puts "Debug: From '#{@state}' To '#{n}' after #{now-(@state_s||stamp)}ms".colorize(:yellow)
    @state=n
    @state_s=now
  end

  def cmd act
    begin
      @holdoff=(@@Commands[act[:cmd]][:holdoff]||Holdoff)*1000.0
      puts "act:#{act} --> #{@holdoff}"
      if act[:cmd]==:send #for raw send , debug console etc.
        puts "Debug: sent '#{act[:str]}'".colorize(:yellow)
        @port.write "#{act[:str]}\r\n"
      elsif act[:cmd]==:init
        puts "\nDebug: Init --------------------------------------------".colorize(:blue)
        newc_state :idle
        @port.write "\r\n" #flush any crap on serial line
        @c_stamps[act[:cmd]]=stamp+10000.0
      elsif @@Commands[act[:cmd]]
        newc_state :incmd
        str=""
        if @@Commands[act[:cmd]][:at]
          str="AT#{@@Commands[act[:cmd]][:at]}"
          if @@Commands[act[:cmd]][:args]
            str+=act[:args]
          end
          @port.write "#{str}\r\n"
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
        puts "cmd #{act} -> <#{str}>  ok: #{@c_ok} tout:#{@c_tout}".colorize(:blue).bold
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
    puts "Debug: C From '#{@c_state}' To '#{n}' after #{now-(@c_state_s||stamp)}ms".colorize(:yellow)
    @c_state=n
    @c_state_s=now
    @c_reply=[]
  end

MODE=1
  def cb_cwmode?
    #+CWMODE:1
    if @c_reply[0][/\+CWMODE:(\d+)/]
      @cwmode=$1.to_i
      puts "MOOOOOOOOOOOOOOOOOOOOOODE #{$1}"
      if @cwmode!=MODE
        sq << {cmd: :cwmode, args:"#{MODE}"}
        sq << {cmd: :cwmode?}
      end
    end
  end
MUX=0
  def cb_cipmux?
    #+CWMODE:1
    if @c_reply[0][/\+CIPMUX:(\d+)/]
      @cipmux=$1.to_i
      puts "CIPMUX MOOOOOOOOOOOOOOOOOOOOOODE #{$1}"
      if @cipmux!=MUX
        sq << {cmd: :cipmux, args:"#{MUX}"}
        sq << {cmd: :cipmux?}
      end
    end
  end


  def cb_cips
    if @c_reply[0][/STATUS:(\d+)/]
      puts "cippi: #{@c_reply} ->#{$1}"
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
      puts "cippi: #{@c_reply} ->#{$1} ->#{@cipstatus}"
    else
      puts "cippi: #{@c_reply} ???"
    end
  end
#AT+CIPSTART="UDP","20.20.20.21",8099
  def cb_aplist #we have completed an command and got this as reply:
    @c_reply.each do |ap|
      puts "ap: #{ap}"
      if ap[/\+CWLAP:\((.+)\)/]
        puts "app: #{$1}"
        f=CSV.parse($1)
        if f[0]
          data=f[0]
          @ap_list[data[1]]={
            security: data[0].to_i,
            signal: data[2].to_i,
            mac: data[3],
            channel: data[4].to_i,
            stamp: stamp,
          }
        end
      end
    end
    pp @ap_list
  end


  def parse_reply s
    now=stamp
    if @c_state==:incmd
      if s==@c_ok
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
        puts ">Error detected! #{@c_last}, took  #{now-@c_state_s}ms , tout #{@c_tout}ms".colorize(:red)
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

  def initialize(hash={})

    @debug=hash[:debug]
    newstate :idle
    @c_last=nil
    @c_state=:idle
    @c_state_s=stamp
    @c_stamps={}
    @holdoff=Holdoff

    @ap_list={}
    @sq=Queue.new
    @sq << {cmd: :reboot}
    @sq << {cmd: :init}
    @sq << {cmd: :ping}
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
                    puts "Debug: periodical #{c}"
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

  def get_port
    @port
  end

end



$stdout.sync = true
options={dev: "/dev/ttyAMA0", debug: true}
$dev=Esp8266.new options

port=$dev.get_port

loop  do
  if $stdin.ready?
    c = $stdin.gets.chop
    puts "got #{c} , #{$dev.c_state}"
    if c[0]==":"
      $dev.sq << {cmd: c[1..-1].to_sym}
    else
      $dev.sq << {cmd: :send, str:c}
    end
  else
    sleep 0.01
  end
end
