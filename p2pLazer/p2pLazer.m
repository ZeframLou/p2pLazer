//
//  p2pLazer.m
//  p2pLazer
//
//  Created by Zebang Liu on 14-2-12.
//  Copyright (c) 2014 Zebang Liu. All rights reserved.
//  Contact: the.great.lzbdd@gmail.com
/*
 This file is part of p2pLazer.
 
 p2pLazer is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.
 
 p2pLazer is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with p2pLazer.  If not, see <http://www.gnu.org/licenses/>.
 */

#import "p2pLazer.h"
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <SystemConfiguration/SystemConfiguration.h>

@protocol PLPortMapperDelegate;
@interface PLPortMapper : NSObject
@property (nonatomic) BOOL started;
@property (nonatomic,strong) id<PLPortMapperDelegate> delegate;

+ (PLPortMapper *)mapperWithPort:(uint16_t)port;
- (void)start;
- (void)stop;
+ (NSString *)publicAddress;
+ (NSString *)privateAddress;
@end

@protocol PLPortMapperDelegate <NSObject>
@optional
- (void)mapper:(PortMapper *)mapper didMapWithSuccess:(BOOL)success;
- (void)mapperDidClose:(PortMapper *)mapper;
@end

@interface PLPortMapper ()
@property (nonatomic,strong) PortMapper *mapper;
@end

@implementation PLPortMapper

static NSMutableDictionary *mapperPool;

@synthesize started,delegate,mapper;

+ (PLPortMapper *)mapperWithPort:(uint16_t)port
{
    PLPortMapper *object;
    if (!mapperPool) {
        mapperPool = [NSMutableDictionary dictionary];
    }
    if ([mapperPool objectForKey:[NSNumber numberWithUnsignedInt:port]]) {
        object = [mapperPool objectForKey:[NSNumber numberWithUnsignedInt:port]];
    }
    else {
        object = [[PLPortMapper alloc]init];
        PortMapper *mapper = [[PortMapper alloc] initWithPort:port];
        mapper.mapTCP = YES;
        mapper.mapUDP = NO;
        object.mapper = mapper;
        [mapperPool setObject:object forKey:[NSNumber numberWithUnsignedInt:port]];
    }
    return object;
}

- (void)start
{
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(portMappingChanged:)
                                                 name: PortMapperChangedNotification
                                               object: nil];
    dispatch_async(dispatch_queue_create("waitMappingResult", NULL), ^{
        [mapper waitTillOpened];
        if (mapper.isMapped) {
            started = YES;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([delegate respondsToSelector:@selector(mapper:didMapWithSuccess:)]) {
                [delegate mapper:mapper didMapWithSuccess:(started)];
            }
        });
    });
}

- (void)stop
{
    started = NO;
    [mapperPool removeObjectForKey:[NSNumber numberWithUnsignedInt:mapper.publicPort]];
    [mapper close];
}

+ (NSString *)publicAddress
{
    return [PortMapper findPublicAddress];
}

+ (NSString *)privateAddress
{
    return [PortMapper localAddress];
}

- (void)portMappingChanged:(NSNotification *)aNotification {
    PortMapper *object = aNotification.object;
    if (object.isMapped == NO) {
        //Mapper closed
        if ([delegate respondsToSelector:@selector(mapperDidClose:)]) {
            [delegate mapperDidClose:object];
        }
    }
}

@end

static const NSInteger KEEP_ALIVE_INTERVAL = 300;//Interval for sending keep alive messages
static NSMutableDictionary *lazerPool;
static NSMutableArray *holepunchTempInfos;
static NSString *serverAddress;
static uint16_t serverPort;

@interface p2pLazer () <GCDAsyncSocketDelegate>

@property (nonatomic,strong) GCDAsyncSocket *tcpSocket;
@property (nonatomic) PLNatTier remoteNatTier;
@property (nonatomic,strong) NSTimer *keepAliveTimer;
@property (nonatomic,strong) void (^connectionBlock)();
@property (nonatomic,strong) NSMutableArray *delegates;

@end

@implementation p2pLazer

@synthesize port,connectedAddress,portMapper,tcpSocket,remoteNatTier,keepAliveTimer,connectionBlock,delegates;

#pragma mark - Initializing

+ (p2pLazer *)p2pLazerWithAddress:(NSString *)address port:(uint16_t)port
{
    if (!holepunchTempInfos) {
        holepunchTempInfos = [NSMutableArray array];
    }
    if (!lazerPool) {
        lazerPool = [NSMutableDictionary dictionary];
    }
    if (!serverAddress) {
        serverAddress = [NSString string];
    }//Prevent crashing
    
    p2pLazer *lazer = [lazerPool objectForKey:[NSString stringWithFormat:@"%@%d",address,port]];
    if (!lazer) {
        lazer = [[p2pLazer alloc]init];
        lazer.portMapper = [PLPortMapper mapperWithPort:port];
        [lazer.portMapper start];
        lazer.delegates = [NSMutableArray array];
        lazer.port = port;
        lazer.tcpSocket = [[GCDAsyncSocket alloc]initWithDelegate:lazer delegateQueue:[p2pLazer delegateQueue]];
        [lazer.tcpSocket startTLS:nil];
        [lazer.tcpSocket acceptOnPort:port error:nil];
        lazer.connectedAddress = address;
        if (address) {
            [lazerPool setObject:lazer forKey:[NSString stringWithFormat:@"%@%d",address,port]];
        }
    }
    return lazer;
}

- (void)addDelegate:(id <p2pLazerDelegate>)object
{
    if (![delegates containsObject:object]) {
        [delegates addObject:object];
    }
}

+ (void)setServerAddress:(NSString *)address
{
    serverAddress = [NSString stringWithString:address];
}

+ (void)setServerPort:(uint16_t)port
{
    serverPort = port;
}

#pragma mark - Sending messages

- (void)writeData:(NSData *)data
{
    if (![tcpSocket isConnected]) {
        NSError *error;
        GCDAsyncSocket *sock = tcpSocket;
        [self connectToHost:connectedAddress onPort:port error:&error completionBlock:^{
            [sock writeData:data withTimeout:30 tag:0];
        }];
        if (!error) {
            remoteNatTier = PLTierNoNatOrNatPmp;
        }
        if (error && !tcpSocket.isConnected) {
            remoteNatTier = PLTierHolePunching;
            GCDAsyncSocket *sock = tcpSocket;
            NSString *address = connectedAddress;
            NSError *error1;
            [self connectToHost:serverAddress onPort:serverPort error:&error1 completionBlock:^{
                [holepunchTempInfos addObject:data];
                [sock writeData:[[p2pLazer messageWithIdentifier:@"COMSRVR" arguments:@[[p2pLazer publicIpAddress],address,[NSString stringWithFormat:@"%d",port]]] dataUsingEncoding:NSUTF8StringEncoding] withTimeout:30 tag:[holepunchTempInfos indexOfObject:data] + 1];
            }];
            if (error1) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    for (id delegate in delegates) {
                        if ([delegate respondsToSelector:@selector(p2pLazer:didNotWriteData:toAddress:error:)]) {
                            [delegate p2pLazer:self didNotWriteData:data toAddress:connectedAddress error:error1];
                        }
                    }
                });
            }
        }
    }
    else
    {
        if (remoteNatTier == PLTierNoNatOrNatPmp || remoteNatTier == PLTierHolePunching) {
            [tcpSocket writeData:data withTimeout:30 tag:0];
        }
        else if (remoteNatTier == PLTierRelay) {
            [self sendRelayData:data toAddress:connectedAddress port:serverPort];
        }
    }
}

- (void)connectToHost:(NSString *)host onPort:(uint16_t)remotePort error:(NSError *__autoreleasing *)error completionBlock:(void (^) (void))block
{
    connectionBlock = block;
    if (!([tcpSocket.connectedHost isEqualToString:host] && tcpSocket.connectedPort == remotePort)) {
        if (tcpSocket.isConnected) {
            [tcpSocket setDelegate:nil];
            [tcpSocket disconnect];
            [tcpSocket setDelegate:self];
        }
        [tcpSocket connectToHost:host onPort:remotePort error:error];
    }
}

- (void)sendServerData:(NSData *)data
{
    if (!tcpSocket.isConnected && ![tcpSocket.connectedHost isEqualToString:serverAddress]) {
        NSError *error;
        [self connectToHost:serverAddress onPort:serverPort error:&error completionBlock:^{
            [tcpSocket writeData:data withTimeout:30 tag:0];
        }];
    }
    else {
        [tcpSocket writeData:data withTimeout:30 tag:0];
    }
}

- (void)sendRelayData:(NSData *)data toAddress:(NSString *)address port:(uint16_t)remotePort
{
    [self sendServerData:[[p2pLazer messageWithIdentifier:@"RELAY" arguments:@[[data base64EncodedString],address,[NSString stringWithFormat:@"%d",port]]] dataUsingEncoding:NSUTF8StringEncoding]];
}

#pragma mark - Keep Alive

- (void)startKeepAliveMessages
{
    keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:KEEP_ALIVE_INTERVAL target:self selector:@selector(sendKeepAliveMessage:) userInfo:nil repeats:YES];
}

- (void)stopKeepAliveMessages
{
    [keepAliveTimer invalidate];
}

- (void)sendKeepAliveMessage:(NSTimer *)timer
{
    [self writeData:[@"" dataUsingEncoding:NSUTF8StringEncoding]];
}

#pragma mark - Closing

- (void)closeConnection
{
    [tcpSocket disconnectAfterReadingAndWriting];
}

#pragma mark - Utilities

+ (NSString *)publicIpAddress {
    NSString *address;
    if ([PLPortMapper publicAddress]) {
        address = [PLPortMapper publicAddress];
    }
    else {
        if ([p2pLazer checkNetWorkIsOk]) {
            NSString *string = [NSString stringWithContentsOfURL:[NSURL URLWithString:@"http://www.checkip.org"] encoding:NSUTF8StringEncoding error:nil];
            address = [string substringWithRange:NSMakeRange([string rangeOfString:@"<span style=\"color: #5d9bD3;\">"].location + 30, [string rangeOfString:@"</span></h1>"].location - ([string rangeOfString:@"<span style=\"color: #5d9bD3;\">"].location + 30))];
        }
    }
    return address;
}

+ (NSString *)privateIpAddress {
    NSString *address;
    if ([PLPortMapper privateAddress]) {
        address = [PLPortMapper privateAddress];
    }
    else {
        address = @"error";
        struct ifaddrs *interfaces = NULL;
        struct ifaddrs *temp_addr = NULL;
        int success = 0;
        // retrieve the current interfaces - returns 0 on success
        success = getifaddrs(&interfaces);
        if (success == 0) {
            // Loop through linked list of interfaces
            temp_addr = interfaces;
            while(temp_addr != NULL) {
                if(temp_addr->ifa_addr->sa_family == AF_INET) {
                    // Check if interface is en0 which is the wifi connection on the iPhone
                    if([[NSString stringWithUTF8String:temp_addr->ifa_name] isEqualToString:@"en0"]) {
                        // Get NSString from C String
                        address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                    }
                }
                temp_addr = temp_addr->ifa_next;
            }
        }
        // Free memory
        freeifaddrs(interfaces);
    }
    
    return address;
}

+ (BOOL)checkNetWorkIsOk{
    struct sockaddr_in zeroAddress;
    bzero(&zeroAddress, sizeof(zeroAddress));
    zeroAddress.sin_len = sizeof(zeroAddress);
    zeroAddress.sin_family = AF_INET;
    
    SCNetworkReachabilityRef defaultRouteReachability = SCNetworkReachabilityCreateWithAddress(NULL, (struct sockaddr *)&zeroAddress);
    SCNetworkReachabilityFlags flags;
    
    BOOL didRetrieveFlags = SCNetworkReachabilityGetFlags(defaultRouteReachability, &flags);
    CFRelease(defaultRouteReachability);
    
    if (!didRetrieveFlags) {
        return NO;
    }
    
    BOOL isReachable = flags & kSCNetworkFlagsReachable;
    BOOL needsConnection = flags & kSCNetworkFlagsConnectionRequired;
    // = flags & kSCNetworkReachabilityFlagsIsWWAN;
    BOOL nonWifi = flags & kSCNetworkReachabilityFlagsTransientConnection;
    BOOL moveNet = flags & kSCNetworkReachabilityFlagsIsDirect;
    
    return ((isReachable && !needsConnection) || nonWifi || moveNet) ? YES : NO;
}

+ (NSString *)messageWithIdentifier:(NSString *)identifier arguments:(NSArray *)arguments
{
    NSString *message = [NSString stringWithFormat:@"ID{%@}ARG{",identifier];
    NSInteger i = 0;
    for (NSString *argument in arguments) {
        message = [message stringByAppendingString:argument];
        if (i != arguments.count - 1) {
            message = [message stringByAppendingString:@"[;]"];
        }
        i += 1;
    }
    message = [message stringByAppendingString:@"}"];
    return message;
}

+ (NSString *)identifierOfMessage:(NSString *)message
{
    NSString *string = [message substringFromIndex:3];
    return [string substringToIndex:[string rangeOfString:@"}ARG{"].location];
}

+ (NSArray *)argumentsOfMessage:(NSString *)message
{
    NSString *argumentsString = [message substringFromIndex:[message rangeOfString:@"ARG{"].location + 4];
    argumentsString = [argumentsString substringToIndex:[argumentsString rangeOfString:@"}PIP{"].location];
    NSArray *arguments = [argumentsString componentsSeparatedByString:@"[;]"];
    return arguments;
}

+ (dispatch_queue_t)delegateQueue
{
    static dispatch_queue_t queue;
    if (!queue) {
        queue = dispatch_queue_create("delegate queue", NULL);
    }
    return queue;
}

+ (dispatch_queue_t)filterQueue
{
    static dispatch_queue_t queue;
    if (!queue) {
        queue = dispatch_queue_create("filter queue", NULL);
    }
    return queue;
}

#pragma mark - GCDAsyncSocketDelegate

- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port
{
    if (connectionBlock) {
        connectionBlock();
    }
}

- (void)socket:(GCDAsyncSocket *)sock didAcceptNewSocket:(GCDAsyncSocket *)newSocket
{
    tcpSocket = newSocket;
    tcpSocket.delegate = self;
    tcpSocket.delegateQueue = [p2pLazer delegateQueue];
    connectedAddress = tcpSocket.connectedHost;
    [lazerPool setObject:self forKey:[NSString stringWithFormat:@"%@%d",connectedAddress,port]];
    [sock readDataWithTimeout:-1 tag:0];
}

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag
{
    [self stopKeepAliveMessages];
    [self startKeepAliveMessages];
    NSString *messageString = [[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
    if ([p2pLazer identifierOfMessage:messageString].length != 0 && [messageString rangeOfString:@"}ARG{"].length != 0) {
        NSString *messageIdentifier = [p2pLazer identifierOfMessage:messageString];
        NSArray *messageArguments = [p2pLazer argumentsOfMessage:messageString];
        if ([messageIdentifier isEqualToString:@"COMCLNT"]) {
            remoteNatTier = PLTierHolePunching;
            NSString *address = [messageArguments objectAtIndex:0];
            NSError *error;
            NSData *messageData = [NSData dataWithData:[holepunchTempInfos objectAtIndex:tag - 1]];
            [holepunchTempInfos replaceObjectAtIndex:tag - 1 withObject:@""];
            BOOL flag = NO;
            for (NSData *data in holepunchTempInfos) {
                flag = YES;
                break;
            }
            if (!flag) {
                [holepunchTempInfos removeAllObjects];
            }
            GCDAsyncSocket *sock = tcpSocket;
            [self connectToHost:address onPort:port error:&error completionBlock:^{
                [sock writeData:messageData withTimeout:30 tag:0];
            }];
            if (error) {
                remoteNatTier = PLTierRelay;
                NSError *error1;
                [self connectToHost:serverAddress onPort:serverPort error:&error1 completionBlock:^{
                    [self sendRelayData:messageData toAddress:address port:port];
                }];
                if (error1) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        for (id delegate in delegates) {
                            if ([delegate respondsToSelector:@selector(p2pLazer:didNotWriteData:toAddress:error:)]) {
                                [delegate p2pLazer:self didNotWriteData:messageData toAddress:address error:error1];
                            }
                        }
                    });
                }
            }
        }
        else if ([messageIdentifier isEqualToString:@"RELAY"]) {
            remoteNatTier = PLTierRelay;
            NSString *dataString = [messageArguments objectAtIndex:0];
            NSString *address = [messageArguments objectAtIndex:1];
            dispatch_async(dispatch_get_main_queue(), ^{
                for (id delegate in delegates) {
                    if ([delegate respondsToSelector:@selector(p2pLazer:didRecieveData:fromAddress:)]) {
                        [delegate p2pLazer:self didRecieveData:[dataString base64DecodedData] fromAddress:address];
                    }
                }
            });
        }
    }
    else
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            for (id delegate in delegates) {
                if ([delegate respondsToSelector:@selector(p2pLazer:didRecieveData:fromAddress:)]) {
                    [delegate p2pLazer:self didRecieveData:data fromAddress:sock.connectedHost];
                }
            }
        });
    }
    [sock readDataWithTimeout:-1 tag:0];
}

- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag
{
    [self stopKeepAliveMessages];
    [self startKeepAliveMessages];
    dispatch_async(dispatch_get_main_queue(), ^{
        for (id delegate in delegates) {
            if ([delegate respondsToSelector:@selector(p2pLazer:didWriteDataToAddress:)]) {
                [delegate p2pLazer:self didWriteDataToAddress:connectedAddress];
            }
        }
    });
    [sock readDataWithTimeout:-1 tag:0];
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err
{
    [self stopKeepAliveMessages];
    dispatch_async(dispatch_get_main_queue(), ^{
        for (id delegate in delegates) {
            if ([delegate respondsToSelector:@selector(p2pLazer:connectionDidCloseWithError:)]) {
                [delegate p2pLazer:self connectionDidCloseWithError:err];
            }
        }
    });
}

@end