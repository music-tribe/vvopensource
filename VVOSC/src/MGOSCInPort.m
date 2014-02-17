
#import "MGOSCInPort.h"
#import "VVOSC.h"




@implementation MGOSCInPort


- (NSString *) description	{
	return [NSString stringWithFormat:@"<MGOSCInPort: %ld>",port];
}
+ (id) createWithPort:(unsigned short)p	{
	MGOSCInPort		*returnMe = [[MGOSCInPort alloc] initWithPort:p labelled:nil];
	if (returnMe == nil)
		return nil;
	return [returnMe autorelease];
}
+ (id) createWithPort:(unsigned short)p labelled:(NSString *)l	{
	MGOSCInPort		*returnMe = [[MGOSCInPort alloc] initWithPort:p labelled:l];
	if (returnMe == nil)
		return nil;
	return [returnMe autorelease];
}
- (id) initWithPort:(unsigned short)p	{
	return [self initWithPort:p labelled:nil];
}
- (id) initWithPort:(unsigned short)p labelled:(NSString *)l	{
	if (self = [super init])	{
		deleted = NO;
		bound = NO;
		sock = -1;
		port = p;
		
		portLabel = nil;
		if (l != nil)
			portLabel = [l copy];
		
		scratchArray = [[NSMutableArray arrayWithCapacity:0] retain];
		
		delegate = nil;
		
		zeroConfDest = nil;
		
		bound = [self createSocket];
		if (!bound)
			goto BAIL;
		
		return self;
	}
	BAIL:
	NSLog(@"\t\terr: %s - BAIL",__func__);
	[self release];
	return nil;
}
- (void) dealloc	{
	//NSLog(@"%s",__func__);
	if (!deleted)
		[self prepareToBeDeleted];
	if (scratchArray != nil)
		[scratchArray release];
	scratchArray = nil;
	
	if (portLabel != nil)
		[portLabel release];
	portLabel = nil;
	
	[super dealloc];
}
- (void) prepareToBeDeleted	{
	//NSLog(@"%s",__func__);
	delegate = nil;
	close(sock);
	sock = -1;
	
	deleted = YES;
}

- (NSDictionary *) createSnapshot	{
	NSMutableDictionary		*returnMe = [NSMutableDictionary dictionaryWithCapacity:0];
	[returnMe setObject:[NSNumber numberWithInt:port] forKey:@"port"];
	if (portLabel != nil)
		[returnMe setObject:portLabel forKey:@"portLabel"];
	return returnMe;
}

- (BOOL) createSocket	{
	//NSLog(@"%s",__func__);
	//	create a UDP socket
	sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
	if (sock < 0)	{
		return NO;
	}
	//	set the socket to non-blocking
	//fcntl(sock, F_SETFL, 0_NONBLOCK);
	/*
	//	specify that the socket can be reused or you may not be able to bind to it
	int			yes = 1;
	if (setsockopt(sock,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(int)) != 0)	{
		NSLog(@"\t\terr %ld at setsockopt A in %s",errno,__func__);
	}
	if (setsockopt(sock,SOL_SOCKET,SO_REUSEPORT,&yes,sizeof(int)) != 0)	{
		NSLog(@"\t\terr %ld at setsockopt B in %s",errno,__func__);
	}
	*/
	//	prep the sockaddr_in struct
	addr.sin_family = AF_INET;
	addr.sin_port = htons(port);
	addr.sin_addr.s_addr = htonl(INADDR_ANY);
	memset(addr.sin_zero, '\0', sizeof(addr.sin_zero));
	//	bind the socket
	if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0)	{
		NSLog(@"\t\terr: couldn't bind socket for OSC");
		return NO;
	}
	
	long			bufSize = 65506;
	if (setsockopt(sock,SOL_SOCKET,SO_RCVBUF,&bufSize,sizeof(long)) != 0)	{
		NSLog(@"\t\terr %ld at setsockopt() in %s",errno,__func__);
	}
	
//	[socketLock unlock];
	return YES;
}
- (void) start	{
	//NSLog(@"%s",__func__);

	//	if there's a port name, create a NSNetService so devices using bonjour know they can send data to me
	if (portLabel != nil)	{
		//NSLog(@"\t\tpublishing zeroConf: %ld, %@ %@",port,CSCopyMachineName(),portLabel);
		if (zeroConfDest != nil)	{
			[zeroConfDest stop];
			[zeroConfDest release];
		}
		zeroConfDest = [[NSNetService alloc]
			initWithDomain:@"local."
			type:@"_osc._udp."
#if IPHONE
			name:[NSString stringWithFormat:@"%@ %@",[[UIDevice currentDevice] name],portLabel]
#else
			name:[NSString stringWithFormat:@"%@ %@",CSCopyMachineName(),portLabel]
#endif
			port:port];
		[zeroConfDest publish];
	}
	else
		NSLog(@"\t\terr: couldn't make zero conf dest, portLabel was nil");
	
}
- (void) stop	{
	//NSLog(@"%s",__func__);
	
	if (![NSThread isMainThread])	{
		[self performSelectorOnMainThread:@selector(stop) withObject:nil waitUntilDone:NO];
		return;
	}
	
	//	stop & release the bonjour service
	if (zeroConfDest != nil)	{
		[zeroConfDest stop];
		[zeroConfDest release];
		zeroConfDest = nil;
	}
}

- (void) checkForPackets:(bool)discard
{
    fd_set				readFileDescriptor;
    int					readyFileCount;
    struct timeval		timeout;
    
    //	set up the file descriptors and timeout struct
    FD_ZERO(&readFileDescriptor);
    FD_SET(sock, &readFileDescriptor);
    timeout.tv_sec = 0;
    timeout.tv_usec = 1000;		//	0.01 secs = 100hz
    
    //	figure out if there are any open file descriptors
    readyFileCount = select(sock+1, &readFileDescriptor, (fd_set *)NULL, (fd_set *)NULL, &timeout);
    if (readyFileCount < 1)	{	//	if there was an error, bail immediately
        if (readyFileCount < 0)	{
            NSLog(@"\t\terr: socket got closed unexpectedly");
        }
    } else {			
        //	if the socket is one of the file descriptors, i need to get data from it
        while (FD_ISSET(sock, &readFileDescriptor))	{
            //NSLog(@"\t\twhile/packet ping");
            struct sockaddr_in		addrFrom;
            memset(&addrFrom,0,sizeof(addrFrom));
            addrFrom.sin_family = AF_INET;
            socklen_t				addrFromLen = sizeof(struct sockaddr_in);
            int						numBytes;
            BOOL					skipThisPacket = NO;
            
            addrFromLen = sizeof(addrFrom);
            const unsigned bufSize = 65506;
            memset(buf, '\0', bufSize);
            numBytes = (int)recvfrom(sock, buf, bufSize, 0, (struct sockaddr *)&addrFrom, &addrFromLen);
            if (numBytes < 1)	{
                NSLog(@"\t\terr on recvfrom: %i",errno);
                skipThisPacket = YES;
            }
            if (numBytes % 4)	{
                NSLog(@"\t\terr: bytes isn't multiple of 4 in %s",__func__);
                skipThisPacket = YES;
            }
            
            if((filterAddress.s_addr != NULL) && (filterAddress.s_addr != addrFrom.sin_addr.s_addr)){
                skipThisPacket = YES;
            }
            
            if (!skipThisPacket)	{
                buf[numBytes] = '\0';
                
                //	if i've reached this point, i have a buffer of the appropriate
                //	length which needs to be parsed.  the buffer doesn't contain
                //	multiple messages, or multiple root-level bundles
                [self
                    parseRawBuffer:buf
                    ofMaxLength:numBytes
                    fromAddr:(unsigned int)addrFrom.sin_addr.s_addr
                    port:(unsigned short)addrFrom.sin_port];
            }
            
            readyFileCount = select(sock+1, &readFileDescriptor, (fd_set *)NULL, (fd_set *)NULL, &timeout);
        }
        //	if there's stuff in the scratch dict, i have to pass the info on to my delegate
        if ([scratchArray count] > 0)	{
            NSArray				*tmpArray = nil;
            tmpArray = [NSArray arrayWithArray:scratchArray];
            [scratchArray removeAllObjects];
            if(!discard) {
                [self handleScratchArray:tmpArray];
            }
        }
    }
}

/*
	this method exists so subclasses of MGOSCInPort can subclass around this for custom behavior
*/
- (void) parseRawBuffer:(unsigned char *)b ofMaxLength:(int)l fromAddr:(unsigned int)txAddr port:(unsigned short)txPort	{
	//NSLog(@"%s ... %s, %ld",__func__,b,l);
	[OSCPacket
		parseRawBuffer:b
		ofMaxLength:l
		toInPort:self
		fromAddr:txAddr
		port:txPort];
}

/*!
	if you don't want to bother with delegates (or you're not using OSCManager), you can override this method in your subclass of MGOSCInPort to receive an array of OSCMessage objects.  by default, this method just calls "receivedOSCMessage:" with the in port's delegate for each of the items in the passed array.
*/
- (void) handleScratchArray:(NSArray *)a	{
	//NSLog(@"%s",__func__);
	if ((delegate != nil) && ([delegate respondsToSelector:@selector(receivedOSCMessage:)]))	{
		for (OSCMessage *anObj in a)	{
			[delegate receivedOSCMessage:anObj];
		}
	}
}
/*
	this method exists so received OSCMessage objects can be added to my scratch dict and scratch array for output.  you should never need to call this method!
*/
- (void) _addMessage:(OSCMessage *)val	{
	//NSLog(@"%s ... %@",__func__,val);
	if (val == nil)
		return;

    //	add the osc path msg to the scratch array
    [scratchArray addObject:val];
}

- (void) _dispatchQuery:(OSCMessage *)m toOutPort:(OSCOutPort *)o	{
	//NSLog(@"%s ... %@, %@",__func__,m,o);
	if (deleted || m==nil || o==nil || (sock==-1))
		return;
	OSCPacket		*pack = [OSCPacket createWithContent:m];
	if (pack == nil)
		return;
	//	make sure the packet doesn't get released if its pool gets drained while i'm sending it
	[pack retain];
	int				numBytesSent = -1;
	long			bufferSize = [pack bufferLength];
	unsigned char	*buff = [pack payload];
	if (buff == nil)	{
		NSLog(@"\t\terr, buff nil in %s",__func__);
		[pack release];
		return;
	}
	struct sockaddr_in	*outAddr = [o addr];

	numBytesSent = (int)sendto(sock,buff,bufferSize,0,(const struct sockaddr *)outAddr,sizeof(*outAddr));
	[pack release];
}

- (unsigned short) port	{
	return port;
}
- (void) setPort:(unsigned short)n	{
	if (n == port)
		return;
	
	unsigned short		oldPort = port;
	
	//	stop & close my socket
	[self stop];
	
	close(sock);
	sock = -1;
	
	//	clear out the scratch dict/array
		if (scratchArray != nil)
			[scratchArray removeAllObjects];
	//	set up with the new port
	bound = NO;
	port = n;
	bound = [self createSocket];
	//	if i'm bound, start- if i'm not bound, something went wrong- use my old port
	if (bound)
		[self start];
	else	{
		//	close the socket
		close(sock);
		sock = -1;
		//	clear out the scratch dict
			if (scratchArray != nil)
				[scratchArray removeAllObjects];
		//	set up with the old port
		bound = NO;
		port = oldPort;
		bound = [self createSocket];
		if (bound)
			[self start];
	}
}

-(void) setRemoteIpAddress:(NSString*)remoteIpAddress{
    inet_pton(AF_INET, [remoteIpAddress UTF8String], &filterAddress);
}

-(NSString*) remoteIpAddress{
    char str[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &(filterAddress.s_addr), str, INET_ADDRSTRLEN);
    NSString *returningString = [[NSString alloc] initWithUTF8String:str];
    [returningString autorelease];
    return (returningString);
}

- (NSString *) portLabel	{
	return portLabel;
}
- (void) setPortLabel:(NSString *)n	{
	if ((n != nil) && (portLabel != nil) && ([n isEqualToString:portLabel]))
		return;
	
	[self stop];
	
	if (portLabel != nil)
		[portLabel release];
	portLabel = nil;
	
	if (n != nil)
		portLabel = [n copy];
	
	[self start];
	
	[[NSNotificationCenter defaultCenter] postNotificationName:OSCInPortsChangedNotification object:nil];
}
- (NSNetService *) zeroConfDest	{
	return zeroConfDest;
}
- (BOOL) bound	{
	return bound;
}
- (NSString *) ipAddressString	{
	if (deleted || !bound)
		return nil;
	return [NSString stringFromRawIPAddress:addr.sin_addr.s_addr];
}
- (id) delegate	{
	return delegate;
}
- (void) setDelegate:(id)n	{
	delegate = n;
}
- (void) setInterval:(double)n	{
	NSLog(@"**** PROBABLY DEPRECATED: %s",__func__);
	/*
	if (threadLooper != nil)
		[threadLooper setInterval:n];
	*/
}


@end
