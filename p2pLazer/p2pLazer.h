//
//  p2pLazer.h
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

#import <Foundation/Foundation.h>
#import "Base64.h"
#import "GCDAsyncSocket.h"
#import "PortMapper.h"

enum PLNatTier {
    PLTierNoNatOrNatPmp = 1,
    PLTierHolePunching = 2,
    PLTierRelay = 3
};
typedef NSUInteger PLNatTier;

@protocol p2pLazerDelegate;
@class PLPortMapper;

@interface p2pLazer : NSObject

@property (nonatomic) uint16_t port;
@property (nonatomic,strong) NSString *connectedAddress;
@property (nonatomic,strong) PLPortMapper *portMapper;

+ (void)setServerAddress:(NSString *)address;
+ (void)setServerPort:(uint16_t)port;
//Because NAT hole punching and relaying requires a server,you need to set these values first.

+ (p2pLazer *)p2pLazerWithAddress:(NSString *)address port:(uint16_t)port;//If an object with the given arguments already exists,the method will return that object instead of creating a new one.
//If you just want an object for listening incoming connections,just use nil for "address",and use the port number you want for "port".

- (void)writeData:(NSData *)data;
- (void)sendServerData:(NSData *)data;

- (void)closeConnection;//Note:if data writing is in progress when you call this method,the connection will be closed after the data has been written.

@end

@protocol p2pLazerDelegate <NSObject>

@optional

/*
 Called when the messenger recieved data.The tag argument is for your own convenience,you can use it as an array index,identifier,etc.
 */
- (void)p2pLazer:(p2pLazer *)lazer didRecieveData:(NSData *)data fromAddress:(NSString *)address;

/*
 Called when the messenger wrote data on a remote storage.The tag argument is for your own convenience,you can use it as an array index,identifier,etc.
 */
- (void)p2pLazer:(p2pLazer *)lazer didWriteDataToAddress:(NSString *)address;

/*
 Called when the messenger's connection has been closed.If the connection was closed by calling closeConnection,the "error" value will be nil.
 */
- (void)p2pLazer:(p2pLazer *)lazer connectionDidCloseWithError:(NSError *)error;

/*
 Called if a message was not sent successfully.
 */
- (void)p2pLazer:(p2pLazer *)lazer didNotWriteData:(NSData *)data toAddress:(NSString *)address error:(NSError *)error;

@end