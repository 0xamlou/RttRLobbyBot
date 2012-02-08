require 'socket'
$version = 'bot v0.1'

class RttRBot
	def initialize(args)
		@rttrUsername = args[:rttrUsername] 
		@rttrPassword = args[:rttrPassword]
		@lobbyAddr = args[:lobbyAddr]
		@lobbyPort = args[:lobbyPort]
		if (@irc = args.has_key?:ircNick) then
			@ircNick = args[:ircNick]
			@ircServer = args[:ircServer]
			@ircPort = args[:ircPort]
			@ircChannels = args[:ircChannels]
		else
			@irc = false
		end
		if(args.has_key?:motdPath) then
			@motdPath = args[:motdPath]
		else
			@motdPath = 'motd'
		end
		@lobbyIgnored = []
		@ircThread = nil
		@lobbyThread = nil
	end

	def leaveLobby
		if defined?@lobbySocket and !@lobbySocket.closed? then
			@lobbySocket.close
		end
	end
	
	def connectLobby
		puts "connecting to lobby..#{@lobbyAddr}:#{@lobbyPort}"
		@lobbySocket = TCPSocket.new(@lobbyAddr, @lobbyPort)
		logReq = ["\000\020", "\000\000\000\000", "\377\000\006\377", "\000\000\000\000", "Krauser", "\000\000\000\000", "southdakota", "\000\000\000\000", "just_a_bot"]
		logReq[1] = [(@rttrUsername.length + @rttrPassword.length + $version.length + 16)].pack("L")
		logReq[3] = [@rttrUsername.length].pack("L").reverse
		logReq[4] = @rttrUsername
		logReq[5] = [@rttrPassword.length].pack("L").reverse
		logReq[6] = @rttrPassword
		logReq[7] = [$version.length].pack("L").reverse
		logReq[8] = $version
		@lobbySocket.print logReq.pack("a2 a4 a4 a4 a#{@rttrUsername.length} a4 a#{@rttrPassword.length} a4 a*")
		@lobbySocket.read 10
		@lobbySocket
		rescue SystemCallError
			puts "Cannot connect! Retrying in 40 sec.."
			sleep(40)
			retry
	end
	
	def sendLobby(message)
		msgReq = ["\002@", "\000\000\000\000","\000\000\000\000", "\000\000\000\004", "lolz"]
		len = message.length + 8
		msgReq[1] = [len].pack "L"
		msgReq[3] = [message.length].pack("L").reverse
		msgReq[4] = message
		@lobbySocket.print msgReq
		message
	end
	
	def ackLobby
		@lobbySocket.print "\x01\x50\x00\x00\x00\x00"
	end
	
	def loadIgnored
		f = File.open('ignore', 'r')
		f.lines.each do |l|
			@lobbyIgnored << l.chomp
		end
		f.close
	end

	def ignore(username)
		if (notIgnored = !(@lobbyIgnored.include? username)) then
			@lobbyIgnored << username
		else
			@lobbyIgnored.delete username
		end		
		File.open('ignore', 'w+') do |f|
			@lobbyIgnored.each{|ignoredUser| f.puts ignoredUser}
		end
		notIgnored
	end

	def ignored?(username)
		@lobbyIgnored.include? username
	end
	
	def handleLobbyInput
		while not (@lobbySocket.eof?) do
			info = @lobbySocket.read 2
			ndata = @lobbySocket.read(4)
			ndata = ndata.unpack("L1").first
			data = @lobbySocket.read(ndata)	
			if(info[1] == 0x40) then
				puts 'read 0x40'
				len = data.length
				i = 0
				while i < len
					user = ""
					message = ""
					n = data[i..i+3].reverse
					n = n.unpack("L1").first
					i += 4
					user = data[i..i + n - 1]
					i += n
					n = data[i..i+3].reverse
					n = n.unpack("L1").first
					i += 4
					message = data[i..i + n - 1]
					i += n
					case message.strip
						when '!ignoreme'
							if ignore(user) then
								sendLobby("#{user} won't receive notifications anymore!")
							else
								sendLobby("#{user} will receive notifications!")
							end
						when '!ignored'
							sendLobby("ignored users are: #{@lobbyIgnored.join', '}")
					end
					sendIRCMessage("#rttr-lobby", "#{user}: #{message}") if user != @rttrUsername
					puts "<#{user}> #{message}"
					smessage = message.split(' ')
					entering_user = smessage.first.chomp.strip
					if(smessage.last == 'betreten' and not (@lobbyIgnored.include? entering_user)) then
						sleep(1)
						sendLobby("Hello #{entering_user}!\n")
						sendLobby(getMotd)
						sendLobby('Type !ignoreme to activate/deactivate these notifications.')
					end
				end
			elsif info[1] == 0x50 then
				puts 'read 0x50'
				ackLobby
			end
		end
	end

	def getMotd
		File.open(@motdPath, 'r'){|f| f.read}
	end

	def start
		loadIgnored
		@lobbyThread = Thread.new do
			connectIRC
			puts 'connected to IRC'
			connectLobby
			puts 'connected to Lobby'
			handleIRCInput
			loop do
				handleLobbyInput
				puts "Lost connection to lobby server! Reconnecting to (#{@lobbyAddr}:#{@lobbyPort}) in 1 min"
				sleep(60)
				connectLobby
			end			
		end
		[@lobbyThread, @ircThread].map(&:join)
	end


#			I	R	C			S	T	U	F	F

    def ircSend(s)
        puts "--> #{s}"
        @ircSocket.send "#{s}\n", 0 
    end
    def connectIRC
	puts 'Connecting to irc server..'
        @ircSocket = TCPSocket.new(@ircServer, @ircPort)
        ircSend "USER RttR Lobby Bot v #{$version} :irc using ruby-socket"
        ircSend "NICK #{@ircNick}"
        ircSend "JOIN #{@ircChannels.join(",")}"
	rescue SystemCallError
		puts 'Error connecting! retrying in 30 sec..'
		sleep(30)
		retry
    end
    
    def evaluate(s)
        if s =~ /^[-+*\/\d\s\eE.()]*$/ then
            begin
                s.untaint
                return eval(s).to_s
            rescue Exception => detail
                puts detail.message()
            end
        end
        return "Error"
    end
    
    def handleIRCInput
        @ircThread = Thread.new do
		loop do
			while !(@ircSocket.eof?) do
				input = @ircSocket.gets.strip
				case input
					when /^PING :(.+)$/i
						#puts "[ Server ping ]"
						ircSend "PONG :#{$1}"
					when /^:(.+?)!(.+?)@(.+?)\sPRIVMSG\s.+\s:[\001]PING (.+)[\001]$/i
						#puts "[ CTCP PING from #{$1}!#{$2}@#{$3} ]"
						ircSend "NOTICE #{$1} :\001PING #{$4}\001"
					when /^:(.+?)!(.+?)@(.+?)\sPRIVMSG\s.+\s:[\001]VERSION[\001]$/i
						#puts "[ CTCP VERSION from #{$1}!#{$2}@#{$3} ]"
						ircSend "NOTICE #{$1} :\001VERSION Ruby-irc v0.042\001"
					when /^:(.+?)!(.+?)@(.+?)\sPRIVMSG\s(.+)\s:EVAL (.+)$/i
						#puts "[ EVAL #{$5} from #{$1}!#{$2}@#{$3} ]"
						ircSend "PRIVMSG #{(($4==@nick)?$1:$4)} :#{evaluate($5)}"
					when /^.*!.*PRIVMSG #{@ircChannels[1]} :.*$/i
						usr = input.scan(/:.*?!/).first.gsub(':', '').gsub('!', '')
						msg = input.scan(/#{@ircChannels[1]} :.*/).first.gsub("#{@ircChannels[1]} :", '')
						sendLobby("#{usr}: #{msg}")
						
					else
						puts input
				end
			end
			puts 'Lost connection to server. Reconnecting in 40 sec'
			sleep(40)
			connectIRC
		end
	end	
	puts 'Irc thread started'
    end

	def sendIRCMessage(channel, message)
		@ircSocket.send "PRIVMSG #{channel} :#{message}\r\n", 0
	end
end


