//
//  TestServer.m
//  p2pLazer
//
//  Created by Zebang Liu on 14-2-19.
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

#import "TestServer.h"
#import "p2pLazer.h"

@interface TestServer () <p2pLazerDelegate>

@end

@implementation TestServer

- (void)p2pLazer:(p2pLazer *)lazer didRecieveData:(NSData *)data tag:(NSInteger)tag
{
    NSString *messageString = [[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
    NSString *messageIdentifier = [TestServer identifierOfMessage:messageString];
    NSArray *messageArguments = [TestServer argumentsOfMessage:messageString];
    if ([messageIdentifier isEqualToString:@"RELAY"]) {
        NSString *dataString = [messageArguments objectAtIndex:0];
        NSString *address = [messageArguments objectAtIndex:1];
        uint16_t remotePort = [[messageArguments objectAtIndex:2]intValue];
        //Relay the message
        p2pLazer *lazer = [p2pLazer p2pLazerWithAddress:address port:remotePort];
        [lazer writeData:[[TestServer messageWithIdentifier:@"RELAY" arguments:@[dataString,lazer.connectedAddress]] dataUsingEncoding:NSUTF8StringEncoding]];
    }
    else if ([messageIdentifier isEqualToString:@"COMSRVR"]) {
        NSString *requesterAddress = [messageArguments objectAtIndex:0];
        NSString *destinationAddress = [messageArguments objectAtIndex:1];
        uint16_t destinationPort = [[messageArguments objectAtIndex:2]intValue];

        //Contact clients
        p2pLazer *lazerA = [p2pLazer p2pLazerWithAddress:destinationAddress port:destinationPort];
        [lazerA writeData:[[TestServer messageWithIdentifier:@"COMCLNT" arguments:@[requesterAddress,[NSString stringWithFormat:@"%d",destinationPort]]]dataUsingEncoding:NSUTF8StringEncoding]];
        [lazer writeData:[[TestServer messageWithIdentifier:@"COMCLNT" arguments:@[destinationAddress,[NSString stringWithFormat:@"%d",destinationPort]]]dataUsingEncoding:NSUTF8StringEncoding]];
    }
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

@end
