//
//  GCDAsyncSocket.m
//  
//  This class is in the public domain.
//  Originally created by Robbie Hanson in Q4 2010.
//  Updated and maintained by Deusty LLC and the Apple development community.
//  Modified by Zebang Liu.
//  For documentation and full version,visit
//  https://github.com/robbiehanson/CocoaAsyncSocket
//

#import "GCDAsyncSocket.h"

#if TARGET_OS_IPHONE
#import <CFNetwork/CFNetwork.h>
#endif

#import <arpa/inet.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <netdb.h>
#import <netinet/in.h>
#import <net/if.h>
#import <sys/socket.h>
#import <sys/types.h>
#import <sys/ioctl.h>
#import <sys/poll.h>
#import <sys/uio.h>
#import <unistd.h>

#if ! __has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
// For more information see: https://github.com/robbiehanson/CocoaAsyncSocket/wiki/ARC
#endif


#if 0

// Logging Enabled - See log level below

// Logging uses the CocoaLumberjack framework (which is also GCD based).
// https://github.com/robbiehanson/CocoaLumberjack
// 
// It allows us to do a lot of logging without significantly slowing down the code.
#import "DDLog.h"

#define LogAsync   YES
#define LogContext 65535

#define LogObjc(flg, frmt, ...) LOG_OBJC_MAYBE(LogAsync, logLevel, flg, LogContext, frmt, ##__VA_ARGS__)
#define LogC(flg, frmt, ...)    LOG_C_MAYBE(LogAsync, logLevel, flg, LogContext, frmt, ##__VA_ARGS__)

#define LogError(frmt, ...)     LogObjc(LOG_FLAG_ERROR,   (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogWarn(frmt, ...)      LogObjc(LOG_FLAG_WARN,    (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogInfo(frmt, ...)      LogObjc(LOG_FLAG_INFO,    (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogVerbose(frmt, ...)   LogObjc(LOG_FLAG_VERBOSE, (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)

#define LogCError(frmt, ...)    LogC(LOG_FLAG_ERROR,   (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogCWarn(frmt, ...)     LogC(LOG_FLAG_WARN,    (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogCInfo(frmt, ...)     LogC(LOG_FLAG_INFO,    (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogCVerbose(frmt, ...)  LogC(LOG_FLAG_VERBOSE, (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)

#define LogTrace()              LogObjc(LOG_FLAG_VERBOSE, @"%@: %@", THIS_FILE, THIS_METHOD)
#define LogCTrace()             LogC(LOG_FLAG_VERBOSE, @"%@: %s", THIS_FILE, __FUNCTION__)

// Log levels : off, error, warn, info, verbose
static const int logLevel = LOG_LEVEL_VERBOSE;

#else

// Logging Disabled

#define LogError(frmt, ...)     {}
#define LogWarn(frmt, ...)      {}
#define LogInfo(frmt, ...)      {}
#define LogVerbose(frmt, ...)   {}

#define LogCError(frmt, ...)    {}
#define LogCWarn(frmt, ...)     {}
#define LogCInfo(frmt, ...)     {}
#define LogCVerbose(frmt, ...)  {}

#define LogTrace()              {}
#define LogCTrace(frmt, ...)    {}

#endif

/**
 * Seeing a return statements within an inner block
 * can sometimes be mistaken for a return point of the enclosing method.
 * This makes inline blocks a bit easier to read.
**/
#define return_from_block  return

/**
 * A socket file descriptor is really just an integer.
 * It represents the index of the socket within the kernel.
 * This makes invalid file descriptor comparisons easier to read.
**/
#define SOCKET_NULL -1


NSString *const GCDAsyncSocketException = @"GCDAsyncSocketException";
NSString *const GCDAsyncSocketErrorDomain = @"GCDAsyncSocketErrorDomain";

NSString *const GCDAsyncSocketQueueName = @"GCDAsyncSocket";
NSString *const GCDAsyncSocketThreadName = @"GCDAsyncSocket-CFStream";

#if SECURE_TRANSPORT_MAYBE_AVAILABLE
NSString *const GCDAsyncSocketSSLCipherSuites = @"GCDAsyncSocketSSLCipherSuites";
#if TARGET_OS_IPHONE
NSString *const GCDAsyncSocketSSLProtocolVersionMin = @"GCDAsyncSocketSSLProtocolVersionMin";
NSString *const GCDAsyncSocketSSLProtocolVersionMax = @"GCDAsyncSocketSSLProtocolVersionMax";
#else
NSString *const GCDAsyncSocketSSLDiffieHellmanParameters = @"GCDAsyncSocketSSLDiffieHellmanParameters";
#endif
#endif

enum GCDAsyncSocketFlags
{
	kSocketStarted                 = 1 <<  0,  
	kConnected                     = 1 <<  1,  
	kForbidReadsWrites             = 1 <<  2,  
	kReadsPaused                   = 1 <<  3,  
	kWritesPaused                  = 1 <<  4,  
	kDisconnectAfterReads          = 1 <<  5,  
	kDisconnectAfterWrites         = 1 <<  6,  
	kSocketCanAcceptBytes          = 1 <<  7,  
	kReadSourceSuspended           = 1 <<  8,  
	kWriteSourceSuspended          = 1 <<  9,  
	kQueuedTLS                     = 1 << 10,  
	kStartingReadTLS               = 1 << 11,  
	kStartingWriteTLS              = 1 << 12,  
	kSocketSecure                  = 1 << 13,  
	kSocketHasReadEOF              = 1 << 14,  
	kReadStreamClosed              = 1 << 15,  
#if TARGET_OS_IPHONE
	kAddedStreamsToRunLoop         = 1 << 16,  
	kUsingCFStreamForTLS           = 1 << 17,  
	kSecureSocketHasBytesAvailable = 1 << 18,  
#endif
};

enum GCDAsyncSocketConfig
{
	kIPv4Disabled              = 1 << 0,  
	kIPv6Disabled              = 1 << 1,  
	kPreferIPv6                = 1 << 2,  
	kAllowHalfDuplexConnection = 1 << 3,  
};

#if TARGET_OS_IPHONE
  static NSThread *cfstreamThread;  
#endif

@interface GCDAsyncSocket ()
{
	uint32_t flags;
	uint16_t config;
	
#if __has_feature(objc_arc_weak)
	__weak id delegate;
#else
	__unsafe_unretained id delegate;
#endif
	dispatch_queue_t delegateQueue;
	
	int socket4FD;
	int socket6FD;
	int connectIndex;
	NSData * connectInterface4;
	NSData * connectInterface6;
	
	dispatch_queue_t socketQueue;
	
	dispatch_source_t accept4Source;
	dispatch_source_t accept6Source;
	dispatch_source_t connectTimer;
	dispatch_source_t readSource;
	dispatch_source_t writeSource;
	dispatch_source_t readTimer;
	dispatch_source_t writeTimer;
	
	NSMutableArray *readQueue;
	NSMutableArray *writeQueue;
	
	GCDAsyncReadPacket *currentRead;
	GCDAsyncWritePacket *currentWrite;
	
	unsigned long socketFDBytesAvailable;
	
	GCDAsyncSocketPreBuffer *preBuffer;
		
#if TARGET_OS_IPHONE
	CFStreamClientContext streamContext;
	CFReadStreamRef readStream;
	CFWriteStreamRef writeStream;
#endif
#if SECURE_TRANSPORT_MAYBE_AVAILABLE
	SSLContextRef sslContext;
	GCDAsyncSocketPreBuffer *sslPreBuffer;
	size_t sslWriteCachedLength;
	OSStatus sslErrCode;
#endif
	
	void *IsOnSocketQueueOrTargetQueueKey;
	
	id userData;
}

- (BOOL)doAccept:(int)socketFD;


- (void)startConnectTimeout:(NSTimeInterval)timeout;
- (void)endConnectTimeout;
- (void)doConnectTimeout;
- (void)lookup:(int)aConnectIndex host:(NSString *)host port:(uint16_t)port;
- (void)lookup:(int)aConnectIndex didSucceedWithAddress4:(NSData *)address4 address6:(NSData *)address6;
- (void)lookup:(int)aConnectIndex didFail:(NSError *)error;
- (BOOL)connectWithAddress4:(NSData *)address4 address6:(NSData *)address6 error:(NSError **)errPtr;
- (void)didConnect:(int)aConnectIndex;
- (void)didNotConnect:(int)aConnectIndex error:(NSError *)error;


- (void)closeWithError:(NSError *)error;
- (void)maybeClose;


- (NSError *)badConfigError:(NSString *)msg;
- (NSError *)badParamError:(NSString *)msg;
- (NSError *)gaiError:(int)gai_error;
- (NSError *)errnoError;
- (NSError *)errnoErrorWithReason:(NSString *)reason;
- (NSError *)connectTimeoutError;
- (NSError *)otherError:(NSString *)msg;


- (NSString *)connectedHost4;
- (NSString *)connectedHost6;
- (uint16_t)connectedPort4;
- (uint16_t)connectedPort6;
- (NSString *)localHost4;
- (NSString *)localHost6;
- (uint16_t)localPort4;
- (uint16_t)localPort6;
- (NSString *)connectedHostFromSocket4:(int)socketFD;
- (NSString *)connectedHostFromSocket6:(int)socketFD;
- (uint16_t)connectedPortFromSocket4:(int)socketFD;
- (uint16_t)connectedPortFromSocket6:(int)socketFD;
- (NSString *)localHostFromSocket4:(int)socketFD;
- (NSString *)localHostFromSocket6:(int)socketFD;
- (uint16_t)localPortFromSocket4:(int)socketFD;
- (uint16_t)localPortFromSocket6:(int)socketFD;


- (void)getInterfaceAddress4:(NSMutableData **)addr4Ptr
                    address6:(NSMutableData **)addr6Ptr
             fromDescription:(NSString *)interfaceDescription
                        port:(uint16_t)port;
- (void)setupReadAndWriteSourcesForNewlyConnectedSocket:(int)socketFD;
- (void)suspendReadSource;
- (void)resumeReadSource;
- (void)suspendWriteSource;
- (void)resumeWriteSource;


- (void)maybeDequeueRead;
- (void)flushSSLBuffers;
- (void)doReadData;
- (void)doReadEOF;
- (void)completeCurrentRead;
- (void)endCurrentRead;
- (void)setupReadTimerWithTimeout:(NSTimeInterval)timeout;
- (void)doReadTimeout;
- (void)doReadTimeoutWithExtension:(NSTimeInterval)timeoutExtension;


- (void)maybeDequeueWrite;
- (void)doWriteData;
- (void)completeCurrentWrite;
- (void)endCurrentWrite;
- (void)setupWriteTimerWithTimeout:(NSTimeInterval)timeout;
- (void)doWriteTimeout;
- (void)doWriteTimeoutWithExtension:(NSTimeInterval)timeoutExtension;


- (void)maybeStartTLS;
#if SECURE_TRANSPORT_MAYBE_AVAILABLE
- (void)ssl_startTLS;
- (void)ssl_continueSSLHandshake;
#endif
#if TARGET_OS_IPHONE
- (void)cf_startTLS;
#endif


#if TARGET_OS_IPHONE
+ (void)startCFStreamThreadIfNeeded;
- (BOOL)createReadAndWriteStream;
- (BOOL)registerForStreamCallbacksIncludingReadWrite:(BOOL)includeReadWrite;
- (BOOL)addStreamsToRunLoop;
- (BOOL)openStreams;
- (void)removeStreamsFromRunLoop;
#endif


+ (NSString *)hostFromSockaddr4:(const struct sockaddr_in *)pSockaddr4;
+ (NSString *)hostFromSockaddr6:(const struct sockaddr_in6 *)pSockaddr6;
+ (uint16_t)portFromSockaddr4:(const struct sockaddr_in *)pSockaddr4;
+ (uint16_t)portFromSockaddr6:(const struct sockaddr_in6 *)pSockaddr6;

@end


#pragma mark -


@interface GCDAsyncSocketPreBuffer : NSObject
{
	uint8_t *preBuffer;
	size_t preBufferSize;
	
	uint8_t *readPointer;
	uint8_t *writePointer;
}

- (id)initWithCapacity:(size_t)numBytes;

- (void)ensureCapacityForWrite:(size_t)numBytes;

- (size_t)availableBytes;
- (uint8_t *)readBuffer;

- (void)getReadBuffer:(uint8_t **)bufferPtr availableBytes:(size_t *)availableBytesPtr;

- (size_t)availableSpace;
- (uint8_t *)writeBuffer;

- (void)getWriteBuffer:(uint8_t **)bufferPtr availableSpace:(size_t *)availableSpacePtr;

- (void)didRead:(size_t)bytesRead;
- (void)didWrite:(size_t)bytesWritten;

- (void)reset;

@end

@implementation GCDAsyncSocketPreBuffer

- (id)initWithCapacity:(size_t)numBytes
{
	if ((self = [super init]))
	{
		preBufferSize = numBytes;
		preBuffer = malloc(preBufferSize);
		
		readPointer = preBuffer;
		writePointer = preBuffer;
	}
	return self;
}

- (void)dealloc
{
	if (preBuffer)
		free(preBuffer);
}

- (void)ensureCapacityForWrite:(size_t)numBytes
{
	size_t availableSpace = preBufferSize - (writePointer - readPointer);
	
	if (numBytes > availableSpace)
	{
		size_t additionalBytes = numBytes - availableSpace;
		
		size_t newPreBufferSize = preBufferSize + additionalBytes;
		uint8_t *newPreBuffer = realloc(preBuffer, newPreBufferSize);
		
		size_t readPointerOffset = readPointer - preBuffer;
		size_t writePointerOffset = writePointer - preBuffer;
		
		preBuffer = newPreBuffer;
		preBufferSize = newPreBufferSize;
		
		readPointer = preBuffer + readPointerOffset;
		writePointer = preBuffer + writePointerOffset;
	}
}

- (size_t)availableBytes
{
	return writePointer - readPointer;
}

- (uint8_t *)readBuffer
{
	return readPointer;
}

- (void)getReadBuffer:(uint8_t **)bufferPtr availableBytes:(size_t *)availableBytesPtr
{
	if (bufferPtr) *bufferPtr = readPointer;
	if (availableBytesPtr) *availableBytesPtr = writePointer - readPointer;
}

- (void)didRead:(size_t)bytesRead
{
	readPointer += bytesRead;
	
	if (readPointer == writePointer)
	{
		
		readPointer  = preBuffer;
		writePointer = preBuffer;
	}
}

- (size_t)availableSpace
{
	return preBufferSize - (writePointer - readPointer);
}

- (uint8_t *)writeBuffer
{
	return writePointer;
}

- (void)getWriteBuffer:(uint8_t **)bufferPtr availableSpace:(size_t *)availableSpacePtr
{
	if (bufferPtr) *bufferPtr = writePointer;
	if (availableSpacePtr) *availableSpacePtr = preBufferSize - (writePointer - readPointer);
}

- (void)didWrite:(size_t)bytesWritten
{
	writePointer += bytesWritten;
}

- (void)reset
{
	readPointer  = preBuffer;
	writePointer = preBuffer;
}

@end


#pragma mark -


@interface GCDAsyncReadPacket : NSObject
{
  @public
	NSMutableData *buffer;
	NSUInteger startOffset;
	NSUInteger bytesDone;
	NSUInteger maxLength;
	NSTimeInterval timeout;
	NSUInteger readLength;
	NSData *term;
	BOOL bufferOwner;
	NSUInteger originalBufferLength;
	long tag;
}
- (id)initWithData:(NSMutableData *)d
       startOffset:(NSUInteger)s
         maxLength:(NSUInteger)m
           timeout:(NSTimeInterval)t
        readLength:(NSUInteger)l
        terminator:(NSData *)e
               tag:(long)i;

- (void)ensureCapacityForAdditionalDataOfLength:(NSUInteger)bytesToRead;

- (NSUInteger)optimalReadLengthWithDefault:(NSUInteger)defaultValue shouldPreBuffer:(BOOL *)shouldPreBufferPtr;

- (NSUInteger)readLengthForNonTermWithHint:(NSUInteger)bytesAvailable;
- (NSUInteger)readLengthForTermWithHint:(NSUInteger)bytesAvailable shouldPreBuffer:(BOOL *)shouldPreBufferPtr;
- (NSUInteger)readLengthForTermWithPreBuffer:(GCDAsyncSocketPreBuffer *)preBuffer found:(BOOL *)foundPtr;

- (NSInteger)searchForTermAfterPreBuffering:(ssize_t)numBytes;

@end

@implementation GCDAsyncReadPacket

- (id)initWithData:(NSMutableData *)d
       startOffset:(NSUInteger)s
         maxLength:(NSUInteger)m
           timeout:(NSTimeInterval)t
        readLength:(NSUInteger)l
        terminator:(NSData *)e
               tag:(long)i
{
	if((self = [super init]))
	{
		bytesDone = 0;
		maxLength = m;
		timeout = t;
		readLength = l;
		term = [e copy];
		tag = i;
		
		if (d)
		{
			buffer = d;
			startOffset = s;
			bufferOwner = NO;
			originalBufferLength = [d length];
		}
		else
		{
			if (readLength > 0)
				buffer = [[NSMutableData alloc] initWithLength:readLength];
			else
				buffer = [[NSMutableData alloc] initWithLength:0];
			
			startOffset = 0;
			bufferOwner = YES;
			originalBufferLength = 0;
		}
	}
	return self;
}

/**
 * Increases the length of the buffer (if needed) to ensure a read of the given size will fit.
**/
- (void)ensureCapacityForAdditionalDataOfLength:(NSUInteger)bytesToRead
{
	NSUInteger buffSize = [buffer length];
	NSUInteger buffUsed = startOffset + bytesDone;
	
	NSUInteger buffSpace = buffSize - buffUsed;
	
	if (bytesToRead > buffSpace)
	{
		NSUInteger buffInc = bytesToRead - buffSpace;
		
		[buffer increaseLengthBy:buffInc];
	}
}

- (NSUInteger)optimalReadLengthWithDefault:(NSUInteger)defaultValue shouldPreBuffer:(BOOL *)shouldPreBufferPtr
{
	NSUInteger result;
	
	if (readLength > 0)
	{
		
		
		result = MIN(defaultValue, (readLength - bytesDone));
		
		if (shouldPreBufferPtr)
			*shouldPreBufferPtr = NO;
	}
	else
	{
		if (maxLength > 0)
			result =  MIN(defaultValue, (maxLength - bytesDone));
		else
			result = defaultValue;
		
		if (shouldPreBufferPtr)
		{
			NSUInteger buffSize = [buffer length];
			NSUInteger buffUsed = startOffset + bytesDone;
			
			NSUInteger buffSpace = buffSize - buffUsed;
			
			if (buffSpace >= result)
				*shouldPreBufferPtr = NO;
			else
				*shouldPreBufferPtr = YES;
		}
	}
	
	return result;
}

- (NSUInteger)readLengthForNonTermWithHint:(NSUInteger)bytesAvailable
{
	NSAssert(term == nil, @"This method does not apply to term reads");
	NSAssert(bytesAvailable > 0, @"Invalid parameter: bytesAvailable");
	
	if (readLength > 0)
	{
		
		
		return MIN(bytesAvailable, (readLength - bytesDone));
	}
	else
	{
		
		
		NSUInteger result = bytesAvailable;
		
		if (maxLength > 0)
		{
			result = MIN(result, (maxLength - bytesDone));
		}
		
		return result;
	}
}

/**
 * For read packets with a set terminator, returns the amount of data
 * that can be read without exceeding the maxLength.
 * 
 * The given parameter indicates the number of bytes estimated to be available on the socket,
 * which is taken into consideration during the calculation.
 * 
 * To optimize memory allocations, mem copies, and mem moves
 * the shouldPreBuffer boolean value will indicate if the data should be read into a prebuffer first,
 * or if the data can be read directly into the read packet's buffer.
**/
- (NSUInteger)readLengthForTermWithHint:(NSUInteger)bytesAvailable shouldPreBuffer:(BOOL *)shouldPreBufferPtr
{
	NSAssert(term != nil, @"This method does not apply to non-term reads");
	NSAssert(bytesAvailable > 0, @"Invalid parameter: bytesAvailable");
	
	
	NSUInteger result = bytesAvailable;
	
	if (maxLength > 0)
	{
		result = MIN(result, (maxLength - bytesDone));
	}
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	if (shouldPreBufferPtr)
	{
		NSUInteger buffSize = [buffer length];
		NSUInteger buffUsed = startOffset + bytesDone;
		
		if ((buffSize - buffUsed) >= result)
			*shouldPreBufferPtr = NO;
		else
			*shouldPreBufferPtr = YES;
	}
	
	return result;
}

/**
 * For read packets with a set terminator,
 * returns the amount of data that can be read from the given preBuffer,
 * without going over a terminator or the maxLength.
 * 
 * It is assumed the terminator has not already been read.
**/
- (NSUInteger)readLengthForTermWithPreBuffer:(GCDAsyncSocketPreBuffer *)preBuffer found:(BOOL *)foundPtr
{
	NSAssert(term != nil, @"This method does not apply to non-term reads");
	NSAssert([preBuffer availableBytes] > 0, @"Invoked with empty pre buffer!");
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	BOOL found = NO;
	
	NSUInteger termLength = [term length];
	NSUInteger preBufferLength = [preBuffer availableBytes];
	
	if ((bytesDone + preBufferLength) < termLength)
	{
		
		return preBufferLength;
	}
	
	NSUInteger maxPreBufferLength;
	if (maxLength > 0) {
		maxPreBufferLength = MIN(preBufferLength, (maxLength - bytesDone));
		
		
	}
	else {
		maxPreBufferLength = preBufferLength;
	}
	
	uint8_t seq[termLength];
	const void *termBuf = [term bytes];
	
	NSUInteger bufLen = MIN(bytesDone, (termLength - 1));
	uint8_t *buf = (uint8_t *)[buffer mutableBytes] + startOffset + bytesDone - bufLen;
	
	NSUInteger preLen = termLength - bufLen;
	const uint8_t *pre = [preBuffer readBuffer];
	
	NSUInteger loopCount = bufLen + maxPreBufferLength - termLength + 1; 
	
	NSUInteger result = maxPreBufferLength;
	
	NSUInteger i;
	for (i = 0; i < loopCount; i++)
	{
		if (bufLen > 0)
		{
			
			
			memcpy(seq, buf, bufLen);
			memcpy(seq + bufLen, pre, preLen);
			
			if (memcmp(seq, termBuf, termLength) == 0)
			{
				result = preLen;
				found = YES;
				break;
			}
			
			buf++;
			bufLen--;
			preLen++;
		}
		else
		{
			
			
			if (memcmp(pre, termBuf, termLength) == 0)
			{
				NSUInteger preOffset = pre - [preBuffer readBuffer]; 
				
				result = preOffset + termLength;
				found = YES;
				break;
			}
			
			pre++;
		}
	}
	
	
	
	if (foundPtr) *foundPtr = found;
	return result;
}

/**
 * For read packets with a set terminator, scans the packet buffer for the term.
 * It is assumed the terminator had not been fully read prior to the new bytes.
 * 
 * If the term is found, the number of excess bytes after the term are returned.
 * If the term is not found, this method will return -1.
 * 
 * Note: A return value of zero means the term was found at the very end.
 * 
 * Prerequisites:
 * The given number of bytes have been added to the end of our buffer.
 * Our bytesDone variable has NOT been changed due to the prebuffered bytes.
**/
- (NSInteger)searchForTermAfterPreBuffering:(ssize_t)numBytes
{
	NSAssert(term != nil, @"This method does not apply to non-term reads");
	
	
	
	
	uint8_t *buff = [buffer mutableBytes];
	NSUInteger buffLength = bytesDone + numBytes;
	
	const void *termBuff = [term bytes];
	NSUInteger termLength = [term length];
	
	
	
	
	NSUInteger i = ((buffLength - numBytes) >= termLength) ? (buffLength - numBytes - termLength + 1) : 0;
	
	while (i + termLength <= buffLength)
	{
		uint8_t *subBuffer = buff + startOffset + i;
		
		if (memcmp(subBuffer, termBuff, termLength) == 0)
		{
			return buffLength - (i + termLength);
		}
		
		i++;
	}
	
	return -1;
}


@end


#pragma mark -


/**
 * The GCDAsyncWritePacket encompasses the instructions for any given write.
**/
@interface GCDAsyncWritePacket : NSObject
{
  @public
	NSData *buffer;
	NSUInteger bytesDone;
	long tag;
	NSTimeInterval timeout;
}
- (id)initWithData:(NSData *)d timeout:(NSTimeInterval)t tag:(long)i;
@end

@implementation GCDAsyncWritePacket

- (id)initWithData:(NSData *)d timeout:(NSTimeInterval)t tag:(long)i
{
	if((self = [super init]))
	{
		buffer = d; 
		bytesDone = 0;
		timeout = t;
		tag = i;
	}
	return self;
}


@end


#pragma mark -


/**
 * The GCDAsyncSpecialPacket encompasses special instructions for interruptions in the read/write queues.
 * This class my be altered to support more than just TLS in the future.
**/
@interface GCDAsyncSpecialPacket : NSObject
{
  @public
	NSDictionary *tlsSettings;
}
- (id)initWithTLSSettings:(NSDictionary *)settings;
@end

@implementation GCDAsyncSpecialPacket

- (id)initWithTLSSettings:(NSDictionary *)settings
{
	if((self = [super init]))
	{
		tlsSettings = [settings copy];
	}
	return self;
}


@end


#pragma mark -


@implementation GCDAsyncSocket

- (id)initWithDelegate:(id)aDelegate delegateQueue:(dispatch_queue_t)dq
{
	return [self initWithDelegate:aDelegate delegateQueue:dq socketQueue:NULL];
}

- (id)initWithDelegate:(id)aDelegate delegateQueue:(dispatch_queue_t)dq socketQueue:(dispatch_queue_t)sq
{
	if((self = [super init]))
	{
		delegate = aDelegate;
		delegateQueue = dq;
		
		#if !OS_OBJECT_USE_OBJC
		if (dq) dispatch_retain(dq);
		#endif
		
		socket4FD = SOCKET_NULL;
		socket6FD = SOCKET_NULL;
		connectIndex = 0;
		
		if (sq)
		{
			NSAssert(sq != dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0),
			         @"The given socketQueue parameter must not be a concurrent queue.");
			NSAssert(sq != dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
			         @"The given socketQueue parameter must not be a concurrent queue.");
			NSAssert(sq != dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
			         @"The given socketQueue parameter must not be a concurrent queue.");
			
			socketQueue = sq;
			#if !OS_OBJECT_USE_OBJC
			dispatch_retain(sq);
			#endif
		}
		else
		{
			socketQueue = dispatch_queue_create([GCDAsyncSocketQueueName UTF8String], NULL);
		}
		
		
		
		
		
		
		
		
		
		
		
		
		
		
		
		
		
		
		IsOnSocketQueueOrTargetQueueKey = &IsOnSocketQueueOrTargetQueueKey;
		
		void *nonNullUnusedPointer = (__bridge void *)self;
		dispatch_queue_set_specific(socketQueue, IsOnSocketQueueOrTargetQueueKey, nonNullUnusedPointer, NULL);
		
		readQueue = [[NSMutableArray alloc] initWithCapacity:5];
		currentRead = nil;
		
		writeQueue = [[NSMutableArray alloc] initWithCapacity:5];
		currentWrite = nil;
		
		preBuffer = [[GCDAsyncSocketPreBuffer alloc] initWithCapacity:(1024 * 4)];
	}
	return self;
}

- (void)dealloc
{
	LogInfo(@"%@ - %@ (start)", THIS_METHOD, self);
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		[self closeWithError:nil];
	}
	else
	{
		dispatch_sync(socketQueue, ^{
			[self closeWithError:nil];
		});
	}
	
	delegate = nil;
	
	#if !OS_OBJECT_USE_OBJC
	if (delegateQueue) dispatch_release(delegateQueue);
	#endif
	delegateQueue = NULL;
	
	#if !OS_OBJECT_USE_OBJC
	if (socketQueue) dispatch_release(socketQueue);
	#endif
	socketQueue = NULL;
	
	LogInfo(@"%@ - %@ (finish)", THIS_METHOD, self);
}


#pragma mark Configuration


- (void)setDelegate:(id)newDelegate synchronously:(BOOL)synchronously
{
	dispatch_block_t block = ^{
		delegate = newDelegate;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey)) {
		block();
	}
	else {
		if (synchronously)
			dispatch_sync(socketQueue, block);
		else
			dispatch_async(socketQueue, block);
	}
}

- (void)setDelegate:(id)newDelegate
{
	[self setDelegate:newDelegate synchronously:NO];
}

- (dispatch_queue_t)delegateQueue
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		return delegateQueue;
	}
	else
	{
		__block dispatch_queue_t result;
		
		dispatch_sync(socketQueue, ^{
			result = delegateQueue;
		});
		
		return result;
	}
}

- (void)setDelegateQueue:(dispatch_queue_t)newDelegateQueue synchronously:(BOOL)synchronously
{
	dispatch_block_t block = ^{
		
		#if !OS_OBJECT_USE_OBJC
		if (delegateQueue) dispatch_release(delegateQueue);
		if (newDelegateQueue) dispatch_retain(newDelegateQueue);
		#endif
		
		delegateQueue = newDelegateQueue;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey)) {
		block();
	}
	else {
		if (synchronously)
			dispatch_sync(socketQueue, block);
		else
			dispatch_async(socketQueue, block);
	}
}

- (void)setDelegateQueue:(dispatch_queue_t)newDelegateQueue
{
	[self setDelegateQueue:newDelegateQueue synchronously:NO];
}

- (id)userData
{
	__block id result = nil;
	
	dispatch_block_t block = ^{
		
		result = userData;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	return result;
}

- (void)setUserData:(id)arbitraryUserData
{
	dispatch_block_t block = ^{
		
		if (userData != arbitraryUserData)
		{
			userData = arbitraryUserData;
		}
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_async(socketQueue, block);
}


#pragma mark Accepting


- (BOOL)acceptOnPort:(uint16_t)port error:(NSError **)errPtr
{
	return [self acceptOnInterface:nil port:port error:errPtr];
}

- (BOOL)acceptOnInterface:(NSString *)inInterface port:(uint16_t)port error:(NSError **)errPtr
{
	LogTrace();
	
	
	NSString *interface = [inInterface copy];
	
	__block BOOL result = NO;
	__block NSError *err = nil;
	
	
	
	
	int(^createSocket)(int, NSData*) = ^int (int domain, NSData *interfaceAddr) {
		
		int socketFD = socket(domain, SOCK_STREAM, 0);
		
		if (socketFD == SOCKET_NULL)
		{
			NSString *reason = @"Error in socket() function";
			err = [self errnoErrorWithReason:reason];
			
			return SOCKET_NULL;
		}
		
		int status;
		
		
		
		status = fcntl(socketFD, F_SETFL, O_NONBLOCK);
		if (status == -1)
		{
			NSString *reason = @"Error enabling non-blocking IO on socket (fcntl)";
			err = [self errnoErrorWithReason:reason];
			
			LogVerbose(@"close(socketFD)");
			close(socketFD);
			return SOCKET_NULL;
		}
		
		int reuseOn = 1;
		status = setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseOn, sizeof(reuseOn));
		if (status == -1)
		{
			NSString *reason = @"Error enabling address reuse (setsockopt)";
			err = [self errnoErrorWithReason:reason];
			
			LogVerbose(@"close(socketFD)");
			close(socketFD);
			return SOCKET_NULL;
		}
		
		
		
		status = bind(socketFD, (const struct sockaddr *)[interfaceAddr bytes], (socklen_t)[interfaceAddr length]);
		if (status == -1)
		{
			NSString *reason = @"Error in bind() function";
			err = [self errnoErrorWithReason:reason];
			
			LogVerbose(@"close(socketFD)");
			close(socketFD);
			return SOCKET_NULL;
		}
		
		
		
		status = listen(socketFD, 1024);
		if (status == -1)
		{
			NSString *reason = @"Error in listen() function";
			err = [self errnoErrorWithReason:reason];
			
			LogVerbose(@"close(socketFD)");
			close(socketFD);
			return SOCKET_NULL;
		}
		
		return socketFD;
	};
	
	
	
	dispatch_block_t block = ^{ @autoreleasepool {
		
		if (delegate == nil) 
		{
			NSString *msg = @"Attempting to accept without a delegate. Set a delegate first.";
			err = [self badConfigError:msg];
			
			return_from_block;
		}
		
		if (delegateQueue == NULL) 
		{
			NSString *msg = @"Attempting to accept without a delegate queue. Set a delegate queue first.";
			err = [self badConfigError:msg];
			
			return_from_block;
		}
		
		BOOL isIPv4Disabled = (config & kIPv4Disabled) ? YES : NO;
		BOOL isIPv6Disabled = (config & kIPv6Disabled) ? YES : NO;
		
		if (isIPv4Disabled && isIPv6Disabled) 
		{
			NSString *msg = @"Both IPv4 and IPv6 have been disabled. Must enable at least one protocol first.";
			err = [self badConfigError:msg];
			
			return_from_block;
		}
		
		if (![self isDisconnected]) 
		{
			NSString *msg = @"Attempting to accept while connected or accepting connections. Disconnect first.";
			err = [self badConfigError:msg];
			
			return_from_block;
		}
		
		
		[readQueue removeAllObjects];
		[writeQueue removeAllObjects];
		
		
		
		NSMutableData *interface4 = nil;
		NSMutableData *interface6 = nil;
		
		[self getInterfaceAddress4:&interface4 address6:&interface6 fromDescription:interface port:port];
		
		if ((interface4 == nil) && (interface6 == nil))
		{
			NSString *msg = @"Unknown interface. Specify valid interface by name (e.g. \"en1\") or IP address.";
			err = [self badParamError:msg];
			
			return_from_block;
		}
		
		if (isIPv4Disabled && (interface6 == nil))
		{
			NSString *msg = @"IPv4 has been disabled and specified interface doesn't support IPv6.";
			err = [self badParamError:msg];
			
			return_from_block;
		}
		
		if (isIPv6Disabled && (interface4 == nil))
		{
			NSString *msg = @"IPv6 has been disabled and specified interface doesn't support IPv4.";
			err = [self badParamError:msg];
			
			return_from_block;
		}
		
		BOOL enableIPv4 = !isIPv4Disabled && (interface4 != nil);
		BOOL enableIPv6 = !isIPv6Disabled && (interface6 != nil);
		
		
		
		if (enableIPv4)
		{
			LogVerbose(@"Creating IPv4 socket");
			socket4FD = createSocket(AF_INET, interface4);
			
			if (socket4FD == SOCKET_NULL)
			{
				return_from_block;
			}
		}
		
		if (enableIPv6)
		{
			LogVerbose(@"Creating IPv6 socket");
			
			if (enableIPv4 && (port == 0))
			{
				
				
				
				struct sockaddr_in6 *addr6 = (struct sockaddr_in6 *)[interface6 mutableBytes];
				addr6->sin6_port = htons([self localPort4]);
			}
			
			socket6FD = createSocket(AF_INET6, interface6);
			
			if (socket6FD == SOCKET_NULL)
			{
				if (socket4FD != SOCKET_NULL)
				{
					LogVerbose(@"close(socket4FD)");
					close(socket4FD);
				}
				
				return_from_block;
			}
		}
		
		
		
		if (enableIPv4)
		{
			accept4Source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, socket4FD, 0, socketQueue);
			
			int socketFD = socket4FD;
			dispatch_source_t acceptSource = accept4Source;
			
			dispatch_source_set_event_handler(accept4Source, ^{ @autoreleasepool {
				
				LogVerbose(@"event4Block");
				
				unsigned long i = 0;
				unsigned long numPendingConnections = dispatch_source_get_data(acceptSource);
				
				LogVerbose(@"numPendingConnections: %lu", numPendingConnections);
				
				while ([self doAccept:socketFD] && (++i < numPendingConnections));
			}});
			
			dispatch_source_set_cancel_handler(accept4Source, ^{
				
				#if !OS_OBJECT_USE_OBJC
				LogVerbose(@"dispatch_release(accept4Source)");
				dispatch_release(acceptSource);
				#endif
				
				LogVerbose(@"close(socket4FD)");
				close(socketFD);
			});
			
			LogVerbose(@"dispatch_resume(accept4Source)");
			dispatch_resume(accept4Source);
		}
		
		if (enableIPv6)
		{
			accept6Source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, socket6FD, 0, socketQueue);
			
			int socketFD = socket6FD;
			dispatch_source_t acceptSource = accept6Source;
			
			dispatch_source_set_event_handler(accept6Source, ^{ @autoreleasepool {
				
				LogVerbose(@"event6Block");
				
				unsigned long i = 0;
				unsigned long numPendingConnections = dispatch_source_get_data(acceptSource);
				
				LogVerbose(@"numPendingConnections: %lu", numPendingConnections);
				
				while ([self doAccept:socketFD] && (++i < numPendingConnections));
			}});
			
			dispatch_source_set_cancel_handler(accept6Source, ^{
				
				#if !OS_OBJECT_USE_OBJC
				LogVerbose(@"dispatch_release(accept6Source)");
				dispatch_release(acceptSource);
				#endif
				
				LogVerbose(@"close(socket6FD)");
				close(socketFD);
			});
			
			LogVerbose(@"dispatch_resume(accept6Source)");
			dispatch_resume(accept6Source);
		}
		
		flags |= kSocketStarted;
		
		result = YES;
	}};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	if (result == NO)
	{
		LogInfo(@"Error in accept: %@", err);
		
		if (errPtr)
			*errPtr = err;
	}
	
	return result;
}

- (BOOL)doAccept:(int)parentSocketFD
{
	LogTrace();
	
	BOOL isIPv4;
	int childSocketFD;
	NSData *childSocketAddress;
	
	if (parentSocketFD == socket4FD)
	{
		isIPv4 = YES;
		
		struct sockaddr_in addr;
		socklen_t addrLen = sizeof(addr);
		
		childSocketFD = accept(parentSocketFD, (struct sockaddr *)&addr, &addrLen);
		
		if (childSocketFD == -1)
		{
			LogWarn(@"Accept failed with error: %@", [self errnoError]);
			return NO;
		}
		
		childSocketAddress = [NSData dataWithBytes:&addr length:addrLen];
	}
	else 
	{
		isIPv4 = NO;
		
		struct sockaddr_in6 addr;
		socklen_t addrLen = sizeof(addr);
		
		childSocketFD = accept(parentSocketFD, (struct sockaddr *)&addr, &addrLen);
		
		if (childSocketFD == -1)
		{
			LogWarn(@"Accept failed with error: %@", [self errnoError]);
			return NO;
		}
		
		childSocketAddress = [NSData dataWithBytes:&addr length:addrLen];
	}
	
	
	
	int result = fcntl(childSocketFD, F_SETFL, O_NONBLOCK);
	if (result == -1)
	{
		LogWarn(@"Error enabling non-blocking IO on accepted socket (fcntl)");
		return NO;
	}
	
	
	
	int nosigpipe = 1;
	setsockopt(childSocketFD, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
	
	
	
	if (delegateQueue)
	{
		__strong id theDelegate = delegate;
		
		dispatch_async(delegateQueue, ^{ @autoreleasepool {
			
			
			
			dispatch_queue_t childSocketQueue = NULL;
			
			if ([theDelegate respondsToSelector:@selector(newSocketQueueForConnectionFromAddress:onSocket:)])
			{
				childSocketQueue = [theDelegate newSocketQueueForConnectionFromAddress:childSocketAddress
				                                                              onSocket:self];
			}
			
			
			
			GCDAsyncSocket *acceptedSocket = [[GCDAsyncSocket alloc] initWithDelegate:theDelegate
			                                                            delegateQueue:delegateQueue
			                                                              socketQueue:childSocketQueue];
			
			if (isIPv4)
				acceptedSocket->socket4FD = childSocketFD;
			else
				acceptedSocket->socket6FD = childSocketFD;
			
			acceptedSocket->flags = (kSocketStarted | kConnected);
			
			
			
			dispatch_async(acceptedSocket->socketQueue, ^{ @autoreleasepool {
				
				[acceptedSocket setupReadAndWriteSourcesForNewlyConnectedSocket:childSocketFD];
			}});
			
			
			
			if ([theDelegate respondsToSelector:@selector(socket:didAcceptNewSocket:)])
			{
				[theDelegate socket:self didAcceptNewSocket:acceptedSocket];
			}
			
			
			#if !OS_OBJECT_USE_OBJC
			if (childSocketQueue) dispatch_release(childSocketQueue);
			#endif
			
			
			
		}});
	}
	
	return YES;
}


#pragma mark Connecting


/**
 * This method runs through the various checks required prior to a connection attempt.
 * It is shared between the connectToHost and connectToAddress methods.
 * 
**/
- (BOOL)preConnectWithInterface:(NSString *)interface error:(NSError **)errPtr
{
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	if (delegate == nil) 
	{
		if (errPtr)
		{
			NSString *msg = @"Attempting to connect without a delegate. Set a delegate first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
	if (delegateQueue == NULL) 
	{
		if (errPtr)
		{
			NSString *msg = @"Attempting to connect without a delegate queue. Set a delegate queue first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
	if (![self isDisconnected]) 
	{
		if (errPtr)
		{
			NSString *msg = @"Attempting to connect while connected or accepting connections. Disconnect first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
	BOOL isIPv4Disabled = (config & kIPv4Disabled) ? YES : NO;
	BOOL isIPv6Disabled = (config & kIPv6Disabled) ? YES : NO;
	
	if (isIPv4Disabled && isIPv6Disabled) 
	{
		if (errPtr)
		{
			NSString *msg = @"Both IPv4 and IPv6 have been disabled. Must enable at least one protocol first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
	if (interface)
	{
		NSMutableData *interface4 = nil;
		NSMutableData *interface6 = nil;
		
		[self getInterfaceAddress4:&interface4 address6:&interface6 fromDescription:interface port:0];
		
		if ((interface4 == nil) && (interface6 == nil))
		{
			if (errPtr)
			{
				NSString *msg = @"Unknown interface. Specify valid interface by name (e.g. \"en1\") or IP address.";
				*errPtr = [self badParamError:msg];
			}
			return NO;
		}
		
		if (isIPv4Disabled && (interface6 == nil))
		{
			if (errPtr)
			{
				NSString *msg = @"IPv4 has been disabled and specified interface doesn't support IPv6.";
				*errPtr = [self badParamError:msg];
			}
			return NO;
		}
		
		if (isIPv6Disabled && (interface4 == nil))
		{
			if (errPtr)
			{
				NSString *msg = @"IPv6 has been disabled and specified interface doesn't support IPv4.";
				*errPtr = [self badParamError:msg];
			}
			return NO;
		}
		
		connectInterface4 = interface4;
		connectInterface6 = interface6;
	}
	
	
	[readQueue removeAllObjects];
	[writeQueue removeAllObjects];
	
	return YES;
}

- (BOOL)connectToHost:(NSString*)host onPort:(uint16_t)port error:(NSError **)errPtr
{
	return [self connectToHost:host onPort:port withTimeout:-1 error:errPtr];
}

- (BOOL)connectToHost:(NSString *)host
               onPort:(uint16_t)port
          withTimeout:(NSTimeInterval)timeout
                error:(NSError **)errPtr
{
	return [self connectToHost:host onPort:port viaInterface:nil withTimeout:timeout error:errPtr];
}

- (BOOL)connectToHost:(NSString *)inHost
               onPort:(uint16_t)port
         viaInterface:(NSString *)inInterface
          withTimeout:(NSTimeInterval)timeout
                error:(NSError **)errPtr
{
	LogTrace();
	
	
	NSString *host = [inHost copy];
	NSString *interface = [inInterface copy];
	
	__block BOOL result = NO;
	__block NSError *err = nil;
	
	dispatch_block_t block = ^{ @autoreleasepool {
		
		
		
		if ([host length] == 0)
		{
			NSString *msg = @"Invalid host parameter (nil or \"\"). Should be a domain name or IP address string.";
			err = [self badParamError:msg];
			
			return_from_block;
		}
		
		
		
		if (![self preConnectWithInterface:interface error:&err])
		{
			return_from_block;
		}
		
		
		
		
		flags |= kSocketStarted;
		
		LogVerbose(@"Dispatching DNS lookup...");
		
		
		
		
		
		int aConnectIndex = connectIndex;
		NSString *hostCpy = [host copy];
		
		dispatch_queue_t globalConcurrentQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
		dispatch_async(globalConcurrentQueue, ^{ @autoreleasepool {
			
			[self lookup:aConnectIndex host:hostCpy port:port];
		}});
		
		[self startConnectTimeout:timeout];
		
		result = YES;
	}};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	if (result == NO)
	{
		if (errPtr)
			*errPtr = err;
	}
	
	return result;
}

- (void)lookup:(int)aConnectIndex host:(NSString *)host port:(uint16_t)port
{
	LogTrace();
	
	
	
	
	
	NSError *error = nil;
	
	NSData *address4 = nil;
	NSData *address6 = nil;
	
	
	if ([host isEqualToString:@"localhost"] || [host isEqualToString:@"loopback"])
	{
		
		struct sockaddr_in nativeAddr;
		nativeAddr.sin_len         = sizeof(struct sockaddr_in);
		nativeAddr.sin_family      = AF_INET;
		nativeAddr.sin_port        = htons(port);
		nativeAddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		memset(&(nativeAddr.sin_zero), 0, sizeof(nativeAddr.sin_zero));
		
		struct sockaddr_in6 nativeAddr6;
		nativeAddr6.sin6_len       = sizeof(struct sockaddr_in6);
		nativeAddr6.sin6_family    = AF_INET6;
		nativeAddr6.sin6_port      = htons(port);
		nativeAddr6.sin6_flowinfo  = 0;
		nativeAddr6.sin6_addr      = in6addr_loopback;
		nativeAddr6.sin6_scope_id  = 0;
		
		
		address4 = [NSData dataWithBytes:&nativeAddr length:sizeof(nativeAddr)];
		address6 = [NSData dataWithBytes:&nativeAddr6 length:sizeof(nativeAddr6)];
	}
	else
	{
		NSString *portStr = [NSString stringWithFormat:@"%hu", port];
		
		struct addrinfo hints, *res, *res0;
		
		memset(&hints, 0, sizeof(hints));
		hints.ai_family   = PF_UNSPEC;
		hints.ai_socktype = SOCK_STREAM;
		hints.ai_protocol = IPPROTO_TCP;
		
		int gai_error = getaddrinfo([host UTF8String], [portStr UTF8String], &hints, &res0);
		
		if (gai_error)
		{
			error = [self gaiError:gai_error];
		}
		else
		{
			for(res = res0; res; res = res->ai_next)
			{
				if ((address4 == nil) && (res->ai_family == AF_INET))
				{
					
					
					address4 = [NSData dataWithBytes:res->ai_addr length:res->ai_addrlen];
				}
				else if ((address6 == nil) && (res->ai_family == AF_INET6))
				{
					
					
					address6 = [NSData dataWithBytes:res->ai_addr length:res->ai_addrlen];
				}
			}
			freeaddrinfo(res0);
			
			if ((address4 == nil) && (address6 == nil))
			{
				error = [self gaiError:EAI_FAIL];
			}
		}
	}
	
	if (error)
	{
		dispatch_async(socketQueue, ^{ @autoreleasepool {
			
			[self lookup:aConnectIndex didFail:error];
		}});
	}
	else
	{
		dispatch_async(socketQueue, ^{ @autoreleasepool {
			
			[self lookup:aConnectIndex didSucceedWithAddress4:address4 address6:address6];
		}});
	}
}

- (void)lookup:(int)aConnectIndex didSucceedWithAddress4:(NSData *)address4 address6:(NSData *)address6
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	NSAssert(address4 || address6, @"Expected at least one valid address");
	
	if (aConnectIndex != connectIndex)
	{
		LogInfo(@"Ignoring lookupDidSucceed, already disconnected");
		
		
		
		return;
	}
	
	
	
	BOOL isIPv4Disabled = (config & kIPv4Disabled) ? YES : NO;
	BOOL isIPv6Disabled = (config & kIPv6Disabled) ? YES : NO;
	
	if (isIPv4Disabled && (address6 == nil))
	{
		NSString *msg = @"IPv4 has been disabled and DNS lookup found no IPv6 address.";
		
		[self closeWithError:[self otherError:msg]];
		return;
	}
	
	if (isIPv6Disabled && (address4 == nil))
	{
		NSString *msg = @"IPv6 has been disabled and DNS lookup found no IPv4 address.";
		
		[self closeWithError:[self otherError:msg]];
		return;
	}
	
	
	
	NSError *err = nil;
	if (![self connectWithAddress4:address4 address6:address6 error:&err])
	{
		[self closeWithError:err];
	}
}

/**
 * This method is called if the DNS lookup fails.
 * This method is executed on the socketQueue.
 * 
 * Since the DNS lookup executed synchronously on a global concurrent queue,
 * the original connection request may have already been cancelled or timed-out by the time this method is invoked.
 * The lookupIndex tells us whether the lookup is still valid or not.
**/
- (void)lookup:(int)aConnectIndex didFail:(NSError *)error
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	
	if (aConnectIndex != connectIndex)
	{
		LogInfo(@"Ignoring lookup:didFail: - already disconnected");
		
		
		
		return;
	}
	
	[self endConnectTimeout];
	[self closeWithError:error];
}

- (BOOL)connectWithAddress4:(NSData *)address4 address6:(NSData *)address6 error:(NSError **)errPtr
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	LogVerbose(@"IPv4: %@:%hu", [[self class] hostFromAddress:address4], [[self class] portFromAddress:address4]);
	LogVerbose(@"IPv6: %@:%hu", [[self class] hostFromAddress:address6], [[self class] portFromAddress:address6]);
	
	
	
	BOOL preferIPv6 = (config & kPreferIPv6) ? YES : NO;
	
	BOOL useIPv6 = ((preferIPv6 && address6) || (address4 == nil));
	
	
	
	int socketFD;
	NSData *address;
	NSData *connectInterface;
	
	if (useIPv6)
	{
		LogVerbose(@"Creating IPv6 socket");
		
		socket6FD = socket(AF_INET6, SOCK_STREAM, 0);
		
		socketFD = socket6FD;
		address = address6;
		connectInterface = connectInterface6;
	}
	else
	{
		LogVerbose(@"Creating IPv4 socket");
		
		socket4FD = socket(AF_INET, SOCK_STREAM, 0);
		
		socketFD = socket4FD;
		address = address4;
		connectInterface = connectInterface4;
	}
	
	if (socketFD == SOCKET_NULL)
	{
		if (errPtr)
			*errPtr = [self errnoErrorWithReason:@"Error in socket() function"];
		
		return NO;
	}
	
	
	
	if (connectInterface)
	{
		LogVerbose(@"Binding socket...");
		
		if ([[self class] portFromAddress:connectInterface] > 0)
		{
			
			
			
			int reuseOn = 1;
			setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseOn, sizeof(reuseOn));
		}
		
		const struct sockaddr *interfaceAddr = (const struct sockaddr *)[connectInterface bytes];
		
		int result = bind(socketFD, interfaceAddr, (socklen_t)[connectInterface length]);
		if (result != 0)
		{
			if (errPtr)
				*errPtr = [self errnoErrorWithReason:@"Error in bind() function"];
			
			return NO;
		}
	}
	
	
	
	int nosigpipe = 1;
	setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
	
	
	
	int aConnectIndex = connectIndex;
	
	dispatch_queue_t globalConcurrentQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
	dispatch_async(globalConcurrentQueue, ^{
		
		int result = connect(socketFD, (const struct sockaddr *)[address bytes], (socklen_t)[address length]);
		if (result == 0)
		{
			dispatch_async(socketQueue, ^{ @autoreleasepool {
				
				[self didConnect:aConnectIndex];
			}});
		}
		else
		{
			NSError *error = [self errnoErrorWithReason:@"Error in connect() function"];
			
			dispatch_async(socketQueue, ^{ @autoreleasepool {
				
				[self didNotConnect:aConnectIndex error:error];
			}});
		}
	});
	
	LogVerbose(@"Connecting...");
	
	return YES;
}

- (void)didConnect:(int)aConnectIndex
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	
	if (aConnectIndex != connectIndex)
	{
		LogInfo(@"Ignoring didConnect, already disconnected");
		
		
		
		return;
	}
	
	flags |= kConnected;
	
	[self endConnectTimeout];
	
	#if TARGET_OS_IPHONE
	
	aConnectIndex = connectIndex;
	#endif
	
	
	
	
	
	
	
	
	
	
	dispatch_block_t SetupStreamsPart1 = ^{
		#if TARGET_OS_IPHONE
		
		if (![self createReadAndWriteStream])
		{
			[self closeWithError:[self otherError:@"Error creating CFStreams"]];
			return;
		}
		
		if (![self registerForStreamCallbacksIncludingReadWrite:NO])
		{
			[self closeWithError:[self otherError:@"Error in CFStreamSetClient"]];
			return;
		}
		
		#endif
	};
	dispatch_block_t SetupStreamsPart2 = ^{
		#if TARGET_OS_IPHONE
		
		if (aConnectIndex != connectIndex)
		{
			
			return;
		}
		
		if (![self addStreamsToRunLoop])
		{
			[self closeWithError:[self otherError:@"Error in CFStreamScheduleWithRunLoop"]];
			return;
		}
		
		if (![self openStreams])
		{
			[self closeWithError:[self otherError:@"Error creating CFStreams"]];
			return;
		}
		
		#endif
	};
	
	
	
	NSString *host = [self connectedHost];
	uint16_t port = [self connectedPort];
	
	if (delegateQueue && [delegate respondsToSelector:@selector(socket:didConnectToHost:port:)])
	{
		SetupStreamsPart1();
		
		__strong id theDelegate = delegate;
		
		dispatch_async(delegateQueue, ^{ @autoreleasepool {
			
			[theDelegate socket:self didConnectToHost:host port:port];
			
			dispatch_async(socketQueue, ^{ @autoreleasepool {
				
				SetupStreamsPart2();
			}});
		}});
	}
	else
	{
		SetupStreamsPart1();
		SetupStreamsPart2();
	}
		
	
	
	int socketFD = (socket4FD != SOCKET_NULL) ? socket4FD : socket6FD;
	
	
	
	int result = fcntl(socketFD, F_SETFL, O_NONBLOCK);
	if (result == -1)
	{
		NSString *errMsg = @"Error enabling non-blocking IO on socket (fcntl)";
		[self closeWithError:[self otherError:errMsg]];
		
		return;
	}
	
	
	
	[self setupReadAndWriteSourcesForNewlyConnectedSocket:socketFD];
	
	
	
	[self maybeDequeueRead];
	[self maybeDequeueWrite];
}

- (void)didNotConnect:(int)aConnectIndex error:(NSError *)error
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	
	if (aConnectIndex != connectIndex)
	{
		LogInfo(@"Ignoring didNotConnect, already disconnected");
		
		
		
		return;
	}
	
	[self closeWithError:error];
}

- (void)startConnectTimeout:(NSTimeInterval)timeout
{
	if (timeout >= 0.0)
	{
		connectTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, socketQueue);
		
		dispatch_source_set_event_handler(connectTimer, ^{ @autoreleasepool {
			
			[self doConnectTimeout];
		}});
		
		#if !OS_OBJECT_USE_OBJC
		dispatch_source_t theConnectTimer = connectTimer;
		dispatch_source_set_cancel_handler(connectTimer, ^{
			LogVerbose(@"dispatch_release(connectTimer)");
			dispatch_release(theConnectTimer);
		});
		#endif
		
		dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
		dispatch_source_set_timer(connectTimer, tt, DISPATCH_TIME_FOREVER, 0);
		
		dispatch_resume(connectTimer);
	}
}

- (void)endConnectTimeout
{
	LogTrace();
	
	if (connectTimer)
	{
		dispatch_source_cancel(connectTimer);
		connectTimer = NULL;
	}
	
	
	
	
	
	
	
	connectIndex++;
	
	if (connectInterface4)
	{
		connectInterface4 = nil;
	}
	if (connectInterface6)
	{
		connectInterface6 = nil;
	}
}

- (void)doConnectTimeout
{
	LogTrace();
	
	[self endConnectTimeout];
	[self closeWithError:[self connectTimeoutError]];
}


#pragma mark Disconnecting


- (void)closeWithError:(NSError *)error
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	
	[self endConnectTimeout];
	
	if (currentRead != nil)  [self endCurrentRead];
	if (currentWrite != nil) [self endCurrentWrite];
	
	[readQueue removeAllObjects];
	[writeQueue removeAllObjects];
	
	[preBuffer reset];
	
	#if TARGET_OS_IPHONE
	{
		if (readStream || writeStream)
		{
			[self removeStreamsFromRunLoop];
			
			if (readStream)
			{
				CFReadStreamSetClient(readStream, kCFStreamEventNone, NULL, NULL);
				CFReadStreamClose(readStream);
				CFRelease(readStream);
				readStream = NULL;
			}
			if (writeStream)
			{
				CFWriteStreamSetClient(writeStream, kCFStreamEventNone, NULL, NULL);
				CFWriteStreamClose(writeStream);
				CFRelease(writeStream);
				writeStream = NULL;
			}
		}
	}
	#endif
	#if SECURE_TRANSPORT_MAYBE_AVAILABLE
	{
		[sslPreBuffer reset];
		sslErrCode = noErr;
		
		if (sslContext)
		{
			
			
			
			SSLClose(sslContext);
			
			#if TARGET_OS_IPHONE
			CFRelease(sslContext);
			#else
			SSLDisposeContext(sslContext);
			#endif
			
			sslContext = NULL;
		}
	}
	#endif
	
	
	
	
	
	
	if (!accept4Source && !accept6Source && !readSource && !writeSource)
	{
		LogVerbose(@"manually closing close");

		if (socket4FD != SOCKET_NULL)
		{
			LogVerbose(@"close(socket4FD)");
			close(socket4FD);
			socket4FD = SOCKET_NULL;
		}

		if (socket6FD != SOCKET_NULL)
		{
			LogVerbose(@"close(socket6FD)");
			close(socket6FD);
			socket6FD = SOCKET_NULL;
		}
	}
	else
	{
		if (accept4Source)
		{
			LogVerbose(@"dispatch_source_cancel(accept4Source)");
			dispatch_source_cancel(accept4Source);
			
			
			
			accept4Source = NULL;
		}
		
		if (accept6Source)
		{
			LogVerbose(@"dispatch_source_cancel(accept6Source)");
			dispatch_source_cancel(accept6Source);
			
			
			
			accept6Source = NULL;
		}
	
		if (readSource)
		{
			LogVerbose(@"dispatch_source_cancel(readSource)");
			dispatch_source_cancel(readSource);
			
			[self resumeReadSource];
			
			readSource = NULL;
		}
		
		if (writeSource)
		{
			LogVerbose(@"dispatch_source_cancel(writeSource)");
			dispatch_source_cancel(writeSource);
			
			[self resumeWriteSource];
			
			writeSource = NULL;
		}
		
		
		
		socket4FD = SOCKET_NULL;
		socket6FD = SOCKET_NULL;
	}
	
	
	
	BOOL shouldCallDelegate = (flags & kSocketStarted);
	
	
	socketFDBytesAvailable = 0;
	flags = 0;
	
	if (shouldCallDelegate)
	{
		if (delegateQueue && [delegate respondsToSelector: @selector(socketDidDisconnect:withError:)])
		{
			__strong id theDelegate = delegate;
			
			dispatch_async(delegateQueue, ^{ @autoreleasepool {
				
				[theDelegate socketDidDisconnect:self withError:error];
			}});
		}	
	}
}

- (void)disconnect
{
	dispatch_block_t block = ^{ @autoreleasepool {
		
		if (flags & kSocketStarted)
		{
			[self closeWithError:nil];
		}
	}};
	
	
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
}

- (void)disconnectAfterReading
{
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
		if (flags & kSocketStarted)
		{
			flags |= (kForbidReadsWrites | kDisconnectAfterReads);
			[self maybeClose];
		}
	}});
}

- (void)disconnectAfterWriting
{
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
		if (flags & kSocketStarted)
		{
			flags |= (kForbidReadsWrites | kDisconnectAfterWrites);
			[self maybeClose];
		}
	}});
}

- (void)disconnectAfterReadingAndWriting
{
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
		if (flags & kSocketStarted)
		{
			flags |= (kForbidReadsWrites | kDisconnectAfterReads | kDisconnectAfterWrites);
			[self maybeClose];
		}
	}});
}

/**
 * Closes the socket if possible.
 * That is, if all writes have completed, and we're set to disconnect after writing,
 * or if all reads have completed, and we're set to disconnect after reading.
**/
- (void)maybeClose
{
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	BOOL shouldClose = NO;
	
	if (flags & kDisconnectAfterReads)
	{
		if (([readQueue count] == 0) && (currentRead == nil))
		{
			if (flags & kDisconnectAfterWrites)
			{
				if (([writeQueue count] == 0) && (currentWrite == nil))
				{
					shouldClose = YES;
				}
			}
			else
			{
				shouldClose = YES;
			}
		}
	}
	else if (flags & kDisconnectAfterWrites)
	{
		if (([writeQueue count] == 0) && (currentWrite == nil))
		{
			shouldClose = YES;
		}
	}
	
	if (shouldClose)
	{
		[self closeWithError:nil];
	}
}


#pragma mark Errors


- (NSError *)badConfigError:(NSString *)errMsg
{
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketBadConfigError userInfo:userInfo];
}

- (NSError *)badParamError:(NSString *)errMsg
{
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketBadParamError userInfo:userInfo];
}

- (NSError *)gaiError:(int)gai_error
{
	NSString *errMsg = [NSString stringWithCString:gai_strerror(gai_error) encoding:NSASCIIStringEncoding];
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	
	return [NSError errorWithDomain:@"kCFStreamErrorDomainNetDB" code:gai_error userInfo:userInfo];
}

- (NSError *)errnoErrorWithReason:(NSString *)reason
{
	NSString *errMsg = [NSString stringWithUTF8String:strerror(errno)];
	NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:errMsg, NSLocalizedDescriptionKey,
	                                                                    reason, NSLocalizedFailureReasonErrorKey, nil];
	
	return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:userInfo];
}

- (NSError *)errnoError
{
	NSString *errMsg = [NSString stringWithUTF8String:strerror(errno)];
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	
	return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:userInfo];
}

- (NSError *)sslError:(OSStatus)ssl_error
{
	NSString *msg = @"Error code definition can be found in Apple's SecureTransport.h";
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:msg forKey:NSLocalizedRecoverySuggestionErrorKey];
	
	return [NSError errorWithDomain:@"kCFStreamErrorDomainSSL" code:ssl_error userInfo:userInfo];
}

- (NSError *)connectTimeoutError
{
	NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketConnectTimeoutError",
	                                                     @"GCDAsyncSocket", [NSBundle mainBundle],
	                                                     @"Attempt to connect to host timed out", nil);
	
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketConnectTimeoutError userInfo:userInfo];
}

/**
 * Returns a standard AsyncSocket maxed out error.
**/
- (NSError *)readMaxedOutError
{
	NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketReadMaxedOutError",
														 @"GCDAsyncSocket", [NSBundle mainBundle],
														 @"Read operation reached set maximum length", nil);
	
	NSDictionary *info = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketReadMaxedOutError userInfo:info];
}

/**
 * Returns a standard AsyncSocket write timeout error.
**/
- (NSError *)readTimeoutError
{
	NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketReadTimeoutError",
	                                                     @"GCDAsyncSocket", [NSBundle mainBundle],
	                                                     @"Read operation timed out", nil);
	
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketReadTimeoutError userInfo:userInfo];
}

/**
 * Returns a standard AsyncSocket write timeout error.
**/
- (NSError *)writeTimeoutError
{
	NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketWriteTimeoutError",
	                                                     @"GCDAsyncSocket", [NSBundle mainBundle],
	                                                     @"Write operation timed out", nil);
	
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketWriteTimeoutError userInfo:userInfo];
}

- (NSError *)connectionClosedError
{
	NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketClosedError",
	                                                     @"GCDAsyncSocket", [NSBundle mainBundle],
	                                                     @"Socket closed by remote peer", nil);
	
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketClosedError userInfo:userInfo];
}

- (NSError *)otherError:(NSString *)errMsg
{
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketOtherError userInfo:userInfo];
}


#pragma mark Diagnostics


- (BOOL)isDisconnected
{
	__block BOOL result = NO;
	
	dispatch_block_t block = ^{
		result = (flags & kSocketStarted) ? NO : YES;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	return result;
}

- (BOOL)isConnected
{
	__block BOOL result = NO;
	
	dispatch_block_t block = ^{
		result = (flags & kConnected) ? YES : NO;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	return result;
}

- (NSString *)connectedHost
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		if (socket4FD != SOCKET_NULL)
			return [self connectedHostFromSocket4:socket4FD];
		if (socket6FD != SOCKET_NULL)
			return [self connectedHostFromSocket6:socket6FD];
		
		return nil;
	}
	else
	{
		__block NSString *result = nil;
		
		dispatch_sync(socketQueue, ^{ @autoreleasepool {
			
			if (socket4FD != SOCKET_NULL)
				result = [self connectedHostFromSocket4:socket4FD];
			else if (socket6FD != SOCKET_NULL)
				result = [self connectedHostFromSocket6:socket6FD];
		}});
		
		return result;
	}
}

- (uint16_t)connectedPort
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		if (socket4FD != SOCKET_NULL)
			return [self connectedPortFromSocket4:socket4FD];
		if (socket6FD != SOCKET_NULL)
			return [self connectedPortFromSocket6:socket6FD];
		
		return 0;
	}
	else
	{
		__block uint16_t result = 0;
		
		dispatch_sync(socketQueue, ^{
			
			
			if (socket4FD != SOCKET_NULL)
				result = [self connectedPortFromSocket4:socket4FD];
			else if (socket6FD != SOCKET_NULL)
				result = [self connectedPortFromSocket6:socket6FD];
		});
		
		return result;
	}
}

- (NSString *)localHost
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		if (socket4FD != SOCKET_NULL)
			return [self localHostFromSocket4:socket4FD];
		if (socket6FD != SOCKET_NULL)
			return [self localHostFromSocket6:socket6FD];
		
		return nil;
	}
	else
	{
		__block NSString *result = nil;
		
		dispatch_sync(socketQueue, ^{ @autoreleasepool {
			
			if (socket4FD != SOCKET_NULL)
				result = [self localHostFromSocket4:socket4FD];
			else if (socket6FD != SOCKET_NULL)
				result = [self localHostFromSocket6:socket6FD];
		}});
		
		return result;
	}
}

- (uint16_t)localPort
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		if (socket4FD != SOCKET_NULL)
			return [self localPortFromSocket4:socket4FD];
		if (socket6FD != SOCKET_NULL)
			return [self localPortFromSocket6:socket6FD];
		
		return 0;
	}
	else
	{
		__block uint16_t result = 0;
		
		dispatch_sync(socketQueue, ^{
			
			
			if (socket4FD != SOCKET_NULL)
				result = [self localPortFromSocket4:socket4FD];
			else if (socket6FD != SOCKET_NULL)
				result = [self localPortFromSocket6:socket6FD];
		});
		
		return result;
	}
}

- (NSString *)connectedHost4
{
	if (socket4FD != SOCKET_NULL)
		return [self connectedHostFromSocket4:socket4FD];
	
	return nil;
}

- (NSString *)connectedHost6
{
	if (socket6FD != SOCKET_NULL)
		return [self connectedHostFromSocket6:socket6FD];
	
	return nil;
}

- (uint16_t)connectedPort4
{
	if (socket4FD != SOCKET_NULL)
		return [self connectedPortFromSocket4:socket4FD];
	
	return 0;
}

- (uint16_t)connectedPort6
{
	if (socket6FD != SOCKET_NULL)
		return [self connectedPortFromSocket6:socket6FD];
	
	return 0;
}

- (NSString *)localHost4
{
	if (socket4FD != SOCKET_NULL)
		return [self localHostFromSocket4:socket4FD];
	
	return nil;
}

- (NSString *)localHost6
{
	if (socket6FD != SOCKET_NULL)
		return [self localHostFromSocket6:socket6FD];
	
	return nil;
}

- (uint16_t)localPort4
{
	if (socket4FD != SOCKET_NULL)
		return [self localPortFromSocket4:socket4FD];
	
	return 0;
}

- (uint16_t)localPort6
{
	if (socket6FD != SOCKET_NULL)
		return [self localPortFromSocket6:socket6FD];
	
	return 0;
}

- (NSString *)connectedHostFromSocket4:(int)socketFD
{
	struct sockaddr_in sockaddr4;
	socklen_t sockaddr4len = sizeof(sockaddr4);
	
	if (getpeername(socketFD, (struct sockaddr *)&sockaddr4, &sockaddr4len) < 0)
	{
		return nil;
	}
	return [[self class] hostFromSockaddr4:&sockaddr4];
}

- (NSString *)connectedHostFromSocket6:(int)socketFD
{
	struct sockaddr_in6 sockaddr6;
	socklen_t sockaddr6len = sizeof(sockaddr6);
	
	if (getpeername(socketFD, (struct sockaddr *)&sockaddr6, &sockaddr6len) < 0)
	{
		return nil;
	}
	return [[self class] hostFromSockaddr6:&sockaddr6];
}

- (uint16_t)connectedPortFromSocket4:(int)socketFD
{
	struct sockaddr_in sockaddr4;
	socklen_t sockaddr4len = sizeof(sockaddr4);
	
	if (getpeername(socketFD, (struct sockaddr *)&sockaddr4, &sockaddr4len) < 0)
	{
		return 0;
	}
	return [[self class] portFromSockaddr4:&sockaddr4];
}

- (uint16_t)connectedPortFromSocket6:(int)socketFD
{
	struct sockaddr_in6 sockaddr6;
	socklen_t sockaddr6len = sizeof(sockaddr6);
	
	if (getpeername(socketFD, (struct sockaddr *)&sockaddr6, &sockaddr6len) < 0)
	{
		return 0;
	}
	return [[self class] portFromSockaddr6:&sockaddr6];
}

- (NSString *)localHostFromSocket4:(int)socketFD
{
	struct sockaddr_in sockaddr4;
	socklen_t sockaddr4len = sizeof(sockaddr4);
	
	if (getsockname(socketFD, (struct sockaddr *)&sockaddr4, &sockaddr4len) < 0)
	{
		return nil;
	}
	return [[self class] hostFromSockaddr4:&sockaddr4];
}

- (NSString *)localHostFromSocket6:(int)socketFD
{
	struct sockaddr_in6 sockaddr6;
	socklen_t sockaddr6len = sizeof(sockaddr6);
	
	if (getsockname(socketFD, (struct sockaddr *)&sockaddr6, &sockaddr6len) < 0)
	{
		return nil;
	}
	return [[self class] hostFromSockaddr6:&sockaddr6];
}

- (uint16_t)localPortFromSocket4:(int)socketFD
{
	struct sockaddr_in sockaddr4;
	socklen_t sockaddr4len = sizeof(sockaddr4);
	
	if (getsockname(socketFD, (struct sockaddr *)&sockaddr4, &sockaddr4len) < 0)
	{
		return 0;
	}
	return [[self class] portFromSockaddr4:&sockaddr4];
}

- (uint16_t)localPortFromSocket6:(int)socketFD
{
	struct sockaddr_in6 sockaddr6;
	socklen_t sockaddr6len = sizeof(sockaddr6);
	
	if (getsockname(socketFD, (struct sockaddr *)&sockaddr6, &sockaddr6len) < 0)
	{
		return 0;
	}
	return [[self class] portFromSockaddr6:&sockaddr6];
}

- (BOOL)isSecure
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		return (flags & kSocketSecure) ? YES : NO;
	}
	else
	{
		__block BOOL result;
		
		dispatch_sync(socketQueue, ^{
			result = (flags & kSocketSecure) ? YES : NO;
		});
		
		return result;
	}
}


#pragma mark Utilities


/**
 * Finds the address of an interface description.
 * An inteface description may be an interface name (en0, en1, lo0) or corresponding IP (192.168.4.34).
 * 
 * The interface description may optionally contain a port number at the end, separated by a colon.
 * If a non-zero port parameter is provided, any port number in the interface description is ignored.
 * 
 * The returned value is a 'struct sockaddr' wrapped in an NSMutableData object.
**/
- (void)getInterfaceAddress4:(NSMutableData **)interfaceAddr4Ptr
                    address6:(NSMutableData **)interfaceAddr6Ptr
             fromDescription:(NSString *)interfaceDescription
                        port:(uint16_t)port
{
	NSMutableData *addr4 = nil;
	NSMutableData *addr6 = nil;
	
	NSString *interface = nil;
	
	NSArray *components = [interfaceDescription componentsSeparatedByString:@":"];
	if ([components count] > 0)
	{
		NSString *temp = [components objectAtIndex:0];
		if ([temp length] > 0)
		{
			interface = temp;
		}
	}
	if ([components count] > 1 && port == 0)
	{
		long portL = strtol([[components objectAtIndex:1] UTF8String], NULL, 10);
		
		if (portL > 0 && portL <= UINT16_MAX)
		{
			port = (uint16_t)portL;
		}
	}
	
	if (interface == nil)
	{
		
		
		struct sockaddr_in sockaddr4;
		memset(&sockaddr4, 0, sizeof(sockaddr4));
		
		sockaddr4.sin_len         = sizeof(sockaddr4);
		sockaddr4.sin_family      = AF_INET;
		sockaddr4.sin_port        = htons(port);
		sockaddr4.sin_addr.s_addr = htonl(INADDR_ANY);
		
		struct sockaddr_in6 sockaddr6;
		memset(&sockaddr6, 0, sizeof(sockaddr6));
		
		sockaddr6.sin6_len       = sizeof(sockaddr6);
		sockaddr6.sin6_family    = AF_INET6;
		sockaddr6.sin6_port      = htons(port);
		sockaddr6.sin6_addr      = in6addr_any;
		
		addr4 = [NSMutableData dataWithBytes:&sockaddr4 length:sizeof(sockaddr4)];
		addr6 = [NSMutableData dataWithBytes:&sockaddr6 length:sizeof(sockaddr6)];
	}
	else if ([interface isEqualToString:@"localhost"] || [interface isEqualToString:@"loopback"])
	{
		
		
		struct sockaddr_in sockaddr4;
		memset(&sockaddr4, 0, sizeof(sockaddr4));
		
		sockaddr4.sin_len         = sizeof(sockaddr4);
		sockaddr4.sin_family      = AF_INET;
		sockaddr4.sin_port        = htons(port);
		sockaddr4.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		
		struct sockaddr_in6 sockaddr6;
		memset(&sockaddr6, 0, sizeof(sockaddr6));
		
		sockaddr6.sin6_len       = sizeof(sockaddr6);
		sockaddr6.sin6_family    = AF_INET6;
		sockaddr6.sin6_port      = htons(port);
		sockaddr6.sin6_addr      = in6addr_loopback;
		
		addr4 = [NSMutableData dataWithBytes:&sockaddr4 length:sizeof(sockaddr4)];
		addr6 = [NSMutableData dataWithBytes:&sockaddr6 length:sizeof(sockaddr6)];
	}
	else
	{
		const char *iface = [interface UTF8String];
		
		struct ifaddrs *addrs;
		const struct ifaddrs *cursor;
		
		if ((getifaddrs(&addrs) == 0))
		{
			cursor = addrs;
			while (cursor != NULL)
			{
				if ((addr4 == nil) && (cursor->ifa_addr->sa_family == AF_INET))
				{
					
					
					struct sockaddr_in nativeAddr4;
					memcpy(&nativeAddr4, cursor->ifa_addr, sizeof(nativeAddr4));
					
					if (strcmp(cursor->ifa_name, iface) == 0)
					{
						
						
						nativeAddr4.sin_port = htons(port);
						
						addr4 = [NSMutableData dataWithBytes:&nativeAddr4 length:sizeof(nativeAddr4)];
					}
					else
					{
						char ip[INET_ADDRSTRLEN];
						
						const char *conversion = inet_ntop(AF_INET, &nativeAddr4.sin_addr, ip, sizeof(ip));
						
						if ((conversion != NULL) && (strcmp(ip, iface) == 0))
						{
							
							
							nativeAddr4.sin_port = htons(port);
							
							addr4 = [NSMutableData dataWithBytes:&nativeAddr4 length:sizeof(nativeAddr4)];
						}
					}
				}
				else if ((addr6 == nil) && (cursor->ifa_addr->sa_family == AF_INET6))
				{
					
					
					struct sockaddr_in6 nativeAddr6;
					memcpy(&nativeAddr6, cursor->ifa_addr, sizeof(nativeAddr6));
					
					if (strcmp(cursor->ifa_name, iface) == 0)
					{
						
						
						nativeAddr6.sin6_port = htons(port);
						
						addr6 = [NSMutableData dataWithBytes:&nativeAddr6 length:sizeof(nativeAddr6)];
					}
					else
					{
						char ip[INET6_ADDRSTRLEN];
						
						const char *conversion = inet_ntop(AF_INET6, &nativeAddr6.sin6_addr, ip, sizeof(ip));
						
						if ((conversion != NULL) && (strcmp(ip, iface) == 0))
						{
							
							
							nativeAddr6.sin6_port = htons(port);
							
							addr6 = [NSMutableData dataWithBytes:&nativeAddr6 length:sizeof(nativeAddr6)];
						}
					}
				}
				
				cursor = cursor->ifa_next;
			}
			
			freeifaddrs(addrs);
		}
	}
	
	if (interfaceAddr4Ptr) *interfaceAddr4Ptr = addr4;
	if (interfaceAddr6Ptr) *interfaceAddr6Ptr = addr6;
}

- (void)setupReadAndWriteSourcesForNewlyConnectedSocket:(int)socketFD
{
	readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, socketFD, 0, socketQueue);
	writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, socketFD, 0, socketQueue);
	
	
	
	dispatch_source_set_event_handler(readSource, ^{ @autoreleasepool {
		
		LogVerbose(@"readEventBlock");
		
		socketFDBytesAvailable = dispatch_source_get_data(readSource);
		LogVerbose(@"socketFDBytesAvailable: %lu", socketFDBytesAvailable);
		
		if (socketFDBytesAvailable > 0)
			[self doReadData];
		else
			[self doReadEOF];
	}});
	
	dispatch_source_set_event_handler(writeSource, ^{ @autoreleasepool {
		
		LogVerbose(@"writeEventBlock");
		
		flags |= kSocketCanAcceptBytes;
		[self doWriteData];
	}});
	
	
	
	__block int socketFDRefCount = 2;
	
	#if !OS_OBJECT_USE_OBJC
	dispatch_source_t theReadSource = readSource;
	dispatch_source_t theWriteSource = writeSource;
	#endif
	
	dispatch_source_set_cancel_handler(readSource, ^{
		
		LogVerbose(@"readCancelBlock");
		
		#if !OS_OBJECT_USE_OBJC
		LogVerbose(@"dispatch_release(readSource)");
		dispatch_release(theReadSource);
		#endif
		
		if (--socketFDRefCount == 0)
		{
			LogVerbose(@"close(socketFD)");
			close(socketFD);
		}
	});
	
	dispatch_source_set_cancel_handler(writeSource, ^{
		
		LogVerbose(@"writeCancelBlock");
		
		#if !OS_OBJECT_USE_OBJC
		LogVerbose(@"dispatch_release(writeSource)");
		dispatch_release(theWriteSource);
		#endif
		
		if (--socketFDRefCount == 0)
		{
			LogVerbose(@"close(socketFD)");
			close(socketFD);
		}
	});
	
	
	
	
	socketFDBytesAvailable = 0;
	flags &= ~kReadSourceSuspended;
	
	LogVerbose(@"dispatch_resume(readSource)");
	dispatch_resume(readSource);
	
	flags |= kSocketCanAcceptBytes;
	flags |= kWriteSourceSuspended;
}

- (BOOL)usingCFStreamForTLS
{
	#if TARGET_OS_IPHONE
	{	
		if ((flags & kSocketSecure) && (flags & kUsingCFStreamForTLS))
		{
			
			
			
			
			
			return YES;
		}
	}
	#endif
	
	return NO;
}

- (BOOL)usingSecureTransportForTLS
{
	#if TARGET_OS_IPHONE
	{
		return ![self usingCFStreamForTLS];
	}
	#endif
	
	return YES;
}

- (void)suspendReadSource
{
	if (!(flags & kReadSourceSuspended))
	{
		LogVerbose(@"dispatch_suspend(readSource)");
		
		dispatch_suspend(readSource);
		flags |= kReadSourceSuspended;
	}
}

- (void)resumeReadSource
{
	if (flags & kReadSourceSuspended)
	{
		LogVerbose(@"dispatch_resume(readSource)");
		
		dispatch_resume(readSource);
		flags &= ~kReadSourceSuspended;
	}
}

- (void)suspendWriteSource
{
	if (!(flags & kWriteSourceSuspended))
	{
		LogVerbose(@"dispatch_suspend(writeSource)");
		
		dispatch_suspend(writeSource);
		flags |= kWriteSourceSuspended;
	}
}

- (void)resumeWriteSource
{
	if (flags & kWriteSourceSuspended)
	{
		LogVerbose(@"dispatch_resume(writeSource)");
		
		dispatch_resume(writeSource);
		flags &= ~kWriteSourceSuspended;
	}
}


#pragma mark Reading


- (void)readDataWithTimeout:(NSTimeInterval)timeout tag:(long)tag
{
	[self readDataWithTimeout:timeout buffer:nil bufferOffset:0 maxLength:0 tag:tag];
}

- (void)readDataWithTimeout:(NSTimeInterval)timeout
                     buffer:(NSMutableData *)buffer
               bufferOffset:(NSUInteger)offset
                        tag:(long)tag
{
	[self readDataWithTimeout:timeout buffer:buffer bufferOffset:offset maxLength:0 tag:tag];
}

- (void)readDataWithTimeout:(NSTimeInterval)timeout
                     buffer:(NSMutableData *)buffer
               bufferOffset:(NSUInteger)offset
                  maxLength:(NSUInteger)length
                        tag:(long)tag
{
	if (offset > [buffer length]) {
		LogWarn(@"Cannot read: offset > [buffer length]");
		return;
	}
	
	GCDAsyncReadPacket *packet = [[GCDAsyncReadPacket alloc] initWithData:buffer
	                                                          startOffset:offset
	                                                            maxLength:length
	                                                              timeout:timeout
	                                                           readLength:0
	                                                           terminator:nil
	                                                                  tag:tag];
	
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
		LogTrace();
		
		if ((flags & kSocketStarted) && !(flags & kForbidReadsWrites))
		{
			[readQueue addObject:packet];
			[self maybeDequeueRead];
		}
	}});
	
	
	
}

- (float)progressOfReadReturningTag:(long *)tagPtr bytesDone:(NSUInteger *)donePtr total:(NSUInteger *)totalPtr
{
	__block float result = 0.0F;
	
	dispatch_block_t block = ^{
		
		if (!currentRead || ![currentRead isKindOfClass:[GCDAsyncReadPacket class]])
		{
			
			
			if (tagPtr != NULL)   *tagPtr = 0;
			if (donePtr != NULL)  *donePtr = 0;
			if (totalPtr != NULL) *totalPtr = 0;
			
			result = NAN;
		}
		else
		{
			
			
			
			
			NSUInteger done = currentRead->bytesDone;
			NSUInteger total = currentRead->readLength;
			
			if (tagPtr != NULL)   *tagPtr = currentRead->tag;
			if (donePtr != NULL)  *donePtr = done;
			if (totalPtr != NULL) *totalPtr = total;
			
			if (total > 0)
				result = (float)done / (float)total;
			else
				result = 1.0F;
		}
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	return result;
}

/**
 * This method starts a new read, if needed.
 * 
 * It is called when:
 * - a user requests a read
 * - after a read request has finished (to handle the next request)
 * - immediately after the socket opens to handle any pending requests
 * 
 * This method also handles auto-disconnect post read/write completion.
**/
- (void)maybeDequeueRead
{
	LogTrace();
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	
	if ((currentRead == nil) && (flags & kConnected))
	{
		if ([readQueue count] > 0)
		{
			
			currentRead = [readQueue objectAtIndex:0];
			[readQueue removeObjectAtIndex:0];
			
			
			if ([currentRead isKindOfClass:[GCDAsyncSpecialPacket class]])
			{
				LogVerbose(@"Dequeued GCDAsyncSpecialPacket");
				
				
				flags |= kStartingReadTLS;
				
				
				[self maybeStartTLS];
			}
			else
			{
				LogVerbose(@"Dequeued GCDAsyncReadPacket");
				
				
				[self setupReadTimerWithTimeout:currentRead->timeout];
				
				
				[self doReadData];
			}
		}
		else if (flags & kDisconnectAfterReads)
		{
			if (flags & kDisconnectAfterWrites)
			{
				if (([writeQueue count] == 0) && (currentWrite == nil))
				{
					[self closeWithError:nil];
				}
			}
			else
			{
				[self closeWithError:nil];
			}
		}
		else if (flags & kSocketSecure)
		{
			[self flushSSLBuffers];
			
			
			
			
			
			
			
			
			
			
			
			if ([preBuffer availableBytes] == 0)
			{
				if ([self usingCFStreamForTLS]) {
					
				}
				else {
					[self resumeReadSource];
				}
			}
		}
	}
}

- (void)flushSSLBuffers
{
	LogTrace();
	
	NSAssert((flags & kSocketSecure), @"Cannot flush ssl buffers on non-secure socket");
	
	if ([preBuffer availableBytes] > 0)
	{
		
		
		
		return;
	}
	
#if TARGET_OS_IPHONE
	
	if ([self usingCFStreamForTLS])
	{
		if ((flags & kSecureSocketHasBytesAvailable) && CFReadStreamHasBytesAvailable(readStream))
		{
			LogVerbose(@"%@ - Flushing ssl buffers into prebuffer...", THIS_METHOD);
			
			CFIndex defaultBytesToRead = (1024 * 4);
			
			[preBuffer ensureCapacityForWrite:defaultBytesToRead];
			
			uint8_t *buffer = [preBuffer writeBuffer];
			
			CFIndex result = CFReadStreamRead(readStream, buffer, defaultBytesToRead);
			LogVerbose(@"%@ - CFReadStreamRead(): result = %i", THIS_METHOD, (int)result);
			
			if (result > 0)
			{
				[preBuffer didWrite:result];
			}
			
			flags &= ~kSecureSocketHasBytesAvailable;
		}
		
		return;
	}
	
#endif
#if SECURE_TRANSPORT_MAYBE_AVAILABLE
	
	__block NSUInteger estimatedBytesAvailable = 0;
	
	dispatch_block_t updateEstimatedBytesAvailable = ^{
		
		
		
		
		
		
		
		
		
		
		
		estimatedBytesAvailable = socketFDBytesAvailable + [sslPreBuffer availableBytes];
		
		size_t sslInternalBufSize = 0;
		SSLGetBufferedReadSize(sslContext, &sslInternalBufSize);
		
		estimatedBytesAvailable += sslInternalBufSize;
	};
	
	updateEstimatedBytesAvailable();
	
	if (estimatedBytesAvailable > 0)
	{
		LogVerbose(@"%@ - Flushing ssl buffers into prebuffer...", THIS_METHOD);
		
		BOOL done = NO;
		do
		{
			LogVerbose(@"%@ - estimatedBytesAvailable = %lu", THIS_METHOD, (unsigned long)estimatedBytesAvailable);
			
			
			
			[preBuffer ensureCapacityForWrite:estimatedBytesAvailable];
			
			
			
			uint8_t *buffer = [preBuffer writeBuffer];
			size_t bytesRead = 0;
			
			OSStatus result = SSLRead(sslContext, buffer, (size_t)estimatedBytesAvailable, &bytesRead);
			LogVerbose(@"%@ - read from secure socket = %u", THIS_METHOD, (unsigned)bytesRead);
			
			if (bytesRead > 0)
			{
				[preBuffer didWrite:bytesRead];
			}
			
			LogVerbose(@"%@ - prebuffer.length = %zu", THIS_METHOD, [preBuffer availableBytes]);
			
			if (result != noErr)
			{
				done = YES;
			}
			else
			{
				updateEstimatedBytesAvailable();
			}
			
		} while (!done && estimatedBytesAvailable > 0);
	}
	
#endif
}

- (void)doReadData
{
	LogTrace();
	
	
	
	
	if ((currentRead == nil) || (flags & kReadsPaused))
	{
		LogVerbose(@"No currentRead or kReadsPaused");
		
		
		
		if (flags & kSocketSecure)
		{
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			[self flushSSLBuffers];
		}
		
		if ([self usingCFStreamForTLS])
		{
			
			
		}
		else
		{
			
			
			
			
			
			
			if (socketFDBytesAvailable > 0)
			{
				[self suspendReadSource];
			}
		}
		return;
	}
	
	BOOL hasBytesAvailable = NO;
	unsigned long estimatedBytesAvailable = 0;
	
	if ([self usingCFStreamForTLS])
	{
		#if TARGET_OS_IPHONE
		
		
		
		estimatedBytesAvailable = 0;
		if ((flags & kSecureSocketHasBytesAvailable) && CFReadStreamHasBytesAvailable(readStream))
			hasBytesAvailable = YES;
		else
			hasBytesAvailable = NO;
		
		#endif
	}
	else
	{
		estimatedBytesAvailable = socketFDBytesAvailable;
		
		#if SECURE_TRANSPORT_MAYBE_AVAILABLE
		
		if (flags & kSocketSecure)
		{
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			estimatedBytesAvailable += [sslPreBuffer availableBytes];
			
			
			
			
			
			
			
			
			
			
			
			
			
			size_t sslInternalBufSize = 0;
			SSLGetBufferedReadSize(sslContext, &sslInternalBufSize);
			
			estimatedBytesAvailable += sslInternalBufSize;
		}
		
		#endif
		
		hasBytesAvailable = (estimatedBytesAvailable > 0);
	}
	
	if ((hasBytesAvailable == NO) && ([preBuffer availableBytes] == 0))
	{
		LogVerbose(@"No data available to read...");
		
		
		
		if (![self usingCFStreamForTLS])
		{
			
			
			
			[self resumeReadSource];
		}
		return;
	}
	
	if (flags & kStartingReadTLS)
	{
		LogVerbose(@"Waiting for SSL/TLS handshake to complete");
		
		
		
		if (flags & kStartingWriteTLS)
		{
			if ([self usingSecureTransportForTLS])
			{
				#if SECURE_TRANSPORT_MAYBE_AVAILABLE
			
				
				
				
				[self ssl_continueSSLHandshake];
			
				#endif
			}
		}
		else
		{
			
			
			
			if (![self usingCFStreamForTLS])
			{
				
				
				[self suspendReadSource];
			}
		}
		
		return;
	}
	
	BOOL done        = NO;  
	NSError *error   = nil; 
	
	NSUInteger totalBytesReadForCurrentRead = 0;
	
	
	
	
	
	if ([preBuffer availableBytes] > 0)
	{
		
		
		
		
		
		
		NSUInteger bytesToCopy;
		
		if (currentRead->term != nil)
		{
			
			
			bytesToCopy = [currentRead readLengthForTermWithPreBuffer:preBuffer found:&done];
		}
		else
		{
			
			
			bytesToCopy = [currentRead readLengthForNonTermWithHint:[preBuffer availableBytes]];
		}
		
		
		
		[currentRead ensureCapacityForAdditionalDataOfLength:bytesToCopy];
		
		
		
		uint8_t *buffer = (uint8_t *)[currentRead->buffer mutableBytes] + currentRead->startOffset +
		                                                                  currentRead->bytesDone;
		
		memcpy(buffer, [preBuffer readBuffer], bytesToCopy);
		
		
		[preBuffer didRead:bytesToCopy];
		
		LogVerbose(@"copied(%lu) preBufferLength(%zu)", (unsigned long)bytesToCopy, [preBuffer availableBytes]);
		
		
		
		currentRead->bytesDone += bytesToCopy;
		totalBytesReadForCurrentRead += bytesToCopy;
		
		
		
		if (currentRead->readLength > 0)
		{
			
			
			done = (currentRead->bytesDone == currentRead->readLength);
		}
		else if (currentRead->term != nil)
		{
			
			
			
			
			if (!done && currentRead->maxLength > 0)
			{
				
				
				
				if (currentRead->bytesDone >= currentRead->maxLength)
				{
					error = [self readMaxedOutError];
				}
			}
		}
		else
		{
			
			
			
			
			
			
			done = ((currentRead->maxLength > 0) && (currentRead->bytesDone == currentRead->maxLength));
		}
		
	}
	
	
	
	
	
	BOOL socketEOF = (flags & kSocketHasReadEOF) ? YES : NO;  
	BOOL waiting   = !done && !error && !socketEOF && !hasBytesAvailable; 
	
	if (!done && !error && !socketEOF && !waiting && hasBytesAvailable)
	{
		NSAssert(([preBuffer availableBytes] == 0), @"Invalid logic");
		
		
		
		
		
		
		
		BOOL readIntoPreBuffer = NO;
		NSUInteger bytesToRead;
		
		if ([self usingCFStreamForTLS])
		{
			
			
			
			
			
			
			
			
			
			NSUInteger defaultReadLength = (1024 * 32);
			
			bytesToRead = [currentRead optimalReadLengthWithDefault:defaultReadLength
			                                        shouldPreBuffer:&readIntoPreBuffer];
		}
		else
		{
			if (currentRead->term != nil)
			{
				
				
				bytesToRead = [currentRead readLengthForTermWithHint:estimatedBytesAvailable
													 shouldPreBuffer:&readIntoPreBuffer];
			}
			else
			{
				
				
				bytesToRead = [currentRead readLengthForNonTermWithHint:estimatedBytesAvailable];
			}
		}
		
		if (bytesToRead > SIZE_MAX) 
		{
			bytesToRead = SIZE_MAX;
		}
		
		
		
		
		
		
		uint8_t *buffer;
		
		if (readIntoPreBuffer)
		{
			[preBuffer ensureCapacityForWrite:bytesToRead];
						
			buffer = [preBuffer writeBuffer];
		}
		else
		{
			[currentRead ensureCapacityForAdditionalDataOfLength:bytesToRead];
			
			buffer = (uint8_t *)[currentRead->buffer mutableBytes] + currentRead->startOffset + currentRead->bytesDone;
		}
		
		
		
		size_t bytesRead = 0;
		
		if (flags & kSocketSecure)
		{
			if ([self usingCFStreamForTLS])
			{
				#if TARGET_OS_IPHONE
				
				CFIndex result = CFReadStreamRead(readStream, buffer, (CFIndex)bytesToRead);
				LogVerbose(@"CFReadStreamRead(): result = %i", (int)result);
				
				if (result < 0)
				{
					error = (__bridge_transfer NSError *)CFReadStreamCopyError(readStream);
				}
				else if (result == 0)
				{
					socketEOF = YES;
				}
				else
				{
					waiting = YES;
					bytesRead = (size_t)result;
				}
				
				
				
				
				flags &= ~kSecureSocketHasBytesAvailable;
				
				#endif
			}
			else
			{
				#if SECURE_TRANSPORT_MAYBE_AVAILABLE
					
				
				
				
				
				
				
				
				
				OSStatus result;
				do
				{
					void *loop_buffer = buffer + bytesRead;
					size_t loop_bytesToRead = (size_t)bytesToRead - bytesRead;
					size_t loop_bytesRead = 0;
					
					result = SSLRead(sslContext, loop_buffer, loop_bytesToRead, &loop_bytesRead);
					LogVerbose(@"read from secure socket = %u", (unsigned)loop_bytesRead);
					
					bytesRead += loop_bytesRead;
					
				} while ((result == noErr) && (bytesRead < bytesToRead));
				
				
				if (result != noErr)
				{
					if (result == errSSLWouldBlock)
						waiting = YES;
					else
					{
						if (result == errSSLClosedGraceful || result == errSSLClosedAbort)
						{
							
							
							socketEOF = YES;
							sslErrCode = result;
						}
						else
						{
							error = [self sslError:result];
						}
					}
					
					
					
					
					if (bytesRead <= 0)
					{
						bytesRead = 0;
					}
				}
				
				
				
				
				#endif
			}
		}
		else
		{
			int socketFD = (socket4FD == SOCKET_NULL) ? socket6FD : socket4FD;
			
			ssize_t result = read(socketFD, buffer, (size_t)bytesToRead);
			LogVerbose(@"read from socket = %i", (int)result);
			
			if (result < 0)
			{
				if (errno == EWOULDBLOCK)
					waiting = YES;
				else
					error = [self errnoErrorWithReason:@"Error in read() function"];
				
				socketFDBytesAvailable = 0;
			}
			else if (result == 0)
			{
				socketEOF = YES;
				socketFDBytesAvailable = 0;
			}
			else
			{
				bytesRead = result;
				
				if (bytesRead < bytesToRead)
				{
					
					
					
					socketFDBytesAvailable = 0;
				}
				else
				{
					if (socketFDBytesAvailable <= bytesRead)
						socketFDBytesAvailable = 0;
					else
						socketFDBytesAvailable -= bytesRead;
				}
				
				if (socketFDBytesAvailable == 0)
				{
					waiting = YES;
				}
			}
		}
		
		if (bytesRead > 0)
		{
			
			
			if (currentRead->readLength > 0)
			{
				
				
				
				
				NSAssert(readIntoPreBuffer == NO, @"Invalid logic");
				
				currentRead->bytesDone += bytesRead;
				totalBytesReadForCurrentRead += bytesRead;
				
				done = (currentRead->bytesDone == currentRead->readLength);
			}
			else if (currentRead->term != nil)
			{
				
				
				if (readIntoPreBuffer)
				{
					
					
					[preBuffer didWrite:bytesRead];
					LogVerbose(@"read data into preBuffer - preBuffer.length = %zu", [preBuffer availableBytes]);
					
					
					
					bytesToRead = [currentRead readLengthForTermWithPreBuffer:preBuffer found:&done];
					LogVerbose(@"copying %lu bytes from preBuffer", (unsigned long)bytesToRead);
					
					
					
					[currentRead ensureCapacityForAdditionalDataOfLength:bytesToRead];
					
					
					
					uint8_t *readBuf = (uint8_t *)[currentRead->buffer mutableBytes] + currentRead->startOffset
					                                                                 + currentRead->bytesDone;
					
					memcpy(readBuf, [preBuffer readBuffer], bytesToRead);
					
					
					[preBuffer didRead:bytesToRead];
					LogVerbose(@"preBuffer.length = %zu", [preBuffer availableBytes]);
					
					
					currentRead->bytesDone += bytesToRead;
					totalBytesReadForCurrentRead += bytesToRead;
					
					
				}
				else
				{
					
					
					
					NSInteger overflow = [currentRead searchForTermAfterPreBuffering:bytesRead];
					
					if (overflow == 0)
					{
						
						
						
						
						currentRead->bytesDone += bytesRead;
						totalBytesReadForCurrentRead += bytesRead;
						done = YES;
					}
					else if (overflow > 0)
					{
						
						
						
						
						NSInteger underflow = bytesRead - overflow;
						
						
						
						LogVerbose(@"copying %ld overflow bytes into preBuffer", (long)overflow);
						[preBuffer ensureCapacityForWrite:overflow];
						
						uint8_t *overflowBuffer = buffer + underflow;
						memcpy([preBuffer writeBuffer], overflowBuffer, overflow);
						
						[preBuffer didWrite:overflow];
						LogVerbose(@"preBuffer.length = %zu", [preBuffer availableBytes]);
						
						
						
						currentRead->bytesDone += underflow;
						totalBytesReadForCurrentRead += underflow;
						done = YES;
					}
					else
					{
						
						
						currentRead->bytesDone += bytesRead;
						totalBytesReadForCurrentRead += bytesRead;
						done = NO;
					}
				}
				
				if (!done && currentRead->maxLength > 0)
				{
					
					
					
					if (currentRead->bytesDone >= currentRead->maxLength)
					{
						error = [self readMaxedOutError];
					}
				}
			}
			else
			{
				
				
				if (readIntoPreBuffer)
				{
					
					
					[preBuffer didWrite:bytesRead];
					
					
					
					
					
					
					
					
					[currentRead ensureCapacityForAdditionalDataOfLength:bytesRead];
					
					
					
					uint8_t *readBuf = (uint8_t *)[currentRead->buffer mutableBytes] + currentRead->startOffset
					                                                                 + currentRead->bytesDone;
					
					memcpy(readBuf, [preBuffer readBuffer], bytesRead);
					
					
					[preBuffer didRead:bytesRead];
					
					
					currentRead->bytesDone += bytesRead;
					totalBytesReadForCurrentRead += bytesRead;
				}
				else
				{
					currentRead->bytesDone += bytesRead;
					totalBytesReadForCurrentRead += bytesRead;
				}
				
				done = YES;
			}
			
		} 
		
	} 
	
	
	if (!done && currentRead->readLength == 0 && currentRead->term == nil)
	{
		
		
		
		
		done = (totalBytesReadForCurrentRead > 0);
	}
	
	
	
	if (done)
	{
		[self completeCurrentRead];
		
		if (!error && (!socketEOF || [preBuffer availableBytes] > 0))
		{
			[self maybeDequeueRead];
		}
	}
	else if (totalBytesReadForCurrentRead > 0)
	{
		
		
		if (delegateQueue && [delegate respondsToSelector:@selector(socket:didReadPartialDataOfLength:tag:)])
		{
			__strong id theDelegate = delegate;
			long theReadTag = currentRead->tag;
			
			dispatch_async(delegateQueue, ^{ @autoreleasepool {
				
				[theDelegate socket:self didReadPartialDataOfLength:totalBytesReadForCurrentRead tag:theReadTag];
			}});
		}
	}
	
	
	
	if (error)
	{
		[self closeWithError:error];
	}
	else if (socketEOF)
	{
		[self doReadEOF];
	}
	else if (waiting)
	{
		if (![self usingCFStreamForTLS])
		{
			
			[self resumeReadSource];
		}
	}
	
	
}

- (void)doReadEOF
{
	LogTrace();
	
	
	
	
	
	flags |= kSocketHasReadEOF;
	
	if (flags & kSocketSecure)
	{
		
		
		[self flushSSLBuffers];
	}
	
	BOOL shouldDisconnect = NO;
	NSError *error = nil;
	
	if ((flags & kStartingReadTLS) || (flags & kStartingWriteTLS))
	{
		
		
		
		shouldDisconnect = YES;
		
		if ([self usingSecureTransportForTLS])
		{
			#if SECURE_TRANSPORT_MAYBE_AVAILABLE
			error = [self sslError:errSSLClosedAbort];
			#endif
		}
	}
	else if (flags & kReadStreamClosed)
	{
		
		
		
		
		
		
		
		
		shouldDisconnect = NO;
	}
	else if ([preBuffer availableBytes] > 0)
	{
		LogVerbose(@"Socket reached EOF, but there is still data available in prebuffer");
		
		
		
		
		shouldDisconnect = NO;
	}
	else if (config & kAllowHalfDuplexConnection)
	{
		
		
		
		
		
		
		int socketFD = (socket4FD == SOCKET_NULL) ? socket6FD : socket4FD;
		
		struct pollfd pfd[1];
		pfd[0].fd = socketFD;
		pfd[0].events = POLLOUT;
		pfd[0].revents = 0;
		
		poll(pfd, 1, 0);
		
		if (pfd[0].revents & POLLOUT)
		{
			
			
			shouldDisconnect = NO;
			flags |= kReadStreamClosed;
			
			
			
			if (delegateQueue && [delegate respondsToSelector:@selector(socketDidCloseReadStream:)])
			{
				__strong id theDelegate = delegate;
				
				dispatch_async(delegateQueue, ^{ @autoreleasepool {
					
					[theDelegate socketDidCloseReadStream:self];
				}});
			}
		}
		else
		{
			shouldDisconnect = YES;
		}
	}
	else
	{
		shouldDisconnect = YES;
	}
	
	
	if (shouldDisconnect)
	{
		if (error == nil)
		{
			#if SECURE_TRANSPORT_MAYBE_AVAILABLE
				if ([self usingSecureTransportForTLS])
				{
					if (sslErrCode != noErr && sslErrCode != errSSLClosedGraceful)
					{
						error = [self sslError:sslErrCode];
					}
					else
					{
						error = [self connectionClosedError];
					}
				}
				else
				{
					error = [self connectionClosedError];
				}
			#else
					error = [self connectionClosedError];
			#endif
		}
		[self closeWithError:error];
	}
	else
	{
		if (![self usingCFStreamForTLS])
		{
			
			
			[self suspendReadSource];
		}
	}
}

- (void)completeCurrentRead
{
	LogTrace();
	
	NSAssert(currentRead, @"Trying to complete current read when there is no current read.");
	
	
	NSData *result = nil;
	
	if (currentRead->bufferOwner)
	{
		
		
		[currentRead->buffer setLength:currentRead->bytesDone];
		
		result = currentRead->buffer;
	}
	else
	{
		
		
		
		
		if ([currentRead->buffer length] > currentRead->originalBufferLength)
		{
			NSUInteger readSize = currentRead->startOffset + currentRead->bytesDone;
			NSUInteger origSize = currentRead->originalBufferLength;
			
			NSUInteger buffSize = MAX(readSize, origSize);
			
			[currentRead->buffer setLength:buffSize];
		}
		
		uint8_t *buffer = (uint8_t *)[currentRead->buffer mutableBytes] + currentRead->startOffset;
		
		result = [NSData dataWithBytesNoCopy:buffer length:currentRead->bytesDone freeWhenDone:NO];
	}
	
	if (delegateQueue && [delegate respondsToSelector:@selector(socket:didReadData:withTag:)])
	{
		__strong id theDelegate = delegate;
		GCDAsyncReadPacket *theRead = currentRead; 
		
		dispatch_async(delegateQueue, ^{ @autoreleasepool {
			
			[theDelegate socket:self didReadData:result withTag:theRead->tag];
		}});
	}
	
	[self endCurrentRead];
}

- (void)endCurrentRead
{
	if (readTimer)
	{
		dispatch_source_cancel(readTimer);
		readTimer = NULL;
	}
	
	currentRead = nil;
}

- (void)setupReadTimerWithTimeout:(NSTimeInterval)timeout
{
	if (timeout >= 0.0)
	{
		readTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, socketQueue);
		
		dispatch_source_set_event_handler(readTimer, ^{ @autoreleasepool {
			
			[self doReadTimeout];
		}});
		
		#if !OS_OBJECT_USE_OBJC
		dispatch_source_t theReadTimer = readTimer;
		dispatch_source_set_cancel_handler(readTimer, ^{
			LogVerbose(@"dispatch_release(readTimer)");
			dispatch_release(theReadTimer);
		});
		#endif
		
		dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
		
		dispatch_source_set_timer(readTimer, tt, DISPATCH_TIME_FOREVER, 0);
		dispatch_resume(readTimer);
	}
}

- (void)doReadTimeout
{
	
	
	
	
	
	flags |= kReadsPaused;
	
	if (delegateQueue && [delegate respondsToSelector:@selector(socket:shouldTimeoutReadWithTag:elapsed:bytesDone:)])
	{
		__strong id theDelegate = delegate;
		GCDAsyncReadPacket *theRead = currentRead;
		
		dispatch_async(delegateQueue, ^{ @autoreleasepool {
			
			NSTimeInterval timeoutExtension = 0.0;
			
			timeoutExtension = [theDelegate socket:self shouldTimeoutReadWithTag:theRead->tag
			                                                             elapsed:theRead->timeout
			                                                           bytesDone:theRead->bytesDone];
			
			dispatch_async(socketQueue, ^{ @autoreleasepool {
				
				[self doReadTimeoutWithExtension:timeoutExtension];
			}});
		}});
	}
	else
	{
		[self doReadTimeoutWithExtension:0.0];
	}
}

- (void)doReadTimeoutWithExtension:(NSTimeInterval)timeoutExtension
{
	if (currentRead)
	{
		if (timeoutExtension > 0.0)
		{
			currentRead->timeout += timeoutExtension;
			
			
			dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutExtension * NSEC_PER_SEC));
			dispatch_source_set_timer(readTimer, tt, DISPATCH_TIME_FOREVER, 0);
			
			
			flags &= ~kReadsPaused;
			[self doReadData];
		}
		else
		{
			LogVerbose(@"ReadTimeout");
			
			[self closeWithError:[self readTimeoutError]];
		}
	}
}


#pragma mark Writing


- (void)writeData:(NSData *)data withTimeout:(NSTimeInterval)timeout tag:(long)tag
{
	if ([data length] == 0) return;
	
	GCDAsyncWritePacket *packet = [[GCDAsyncWritePacket alloc] initWithData:data timeout:timeout tag:tag];
	
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
		LogTrace();
		
		if ((flags & kSocketStarted) && !(flags & kForbidReadsWrites))
		{
			[writeQueue addObject:packet];
			[self maybeDequeueWrite];
		}
	}});
	
	
	
}

- (float)progressOfWriteReturningTag:(long *)tagPtr bytesDone:(NSUInteger *)donePtr total:(NSUInteger *)totalPtr
{
	__block float result = 0.0F;
	
	dispatch_block_t block = ^{
		
		if (!currentWrite || ![currentWrite isKindOfClass:[GCDAsyncWritePacket class]])
		{
			
			
			if (tagPtr != NULL)   *tagPtr = 0;
			if (donePtr != NULL)  *donePtr = 0;
			if (totalPtr != NULL) *totalPtr = 0;
			
			result = NAN;
		}
		else
		{
			NSUInteger done = currentWrite->bytesDone;
			NSUInteger total = [currentWrite->buffer length];
			
			if (tagPtr != NULL)   *tagPtr = currentWrite->tag;
			if (donePtr != NULL)  *donePtr = done;
			if (totalPtr != NULL) *totalPtr = total;
			
			result = (float)done / (float)total;
		}
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	return result;
}

/**
 * Conditionally starts a new write.
 * 
 * It is called when:
 * - a user requests a write
 * - after a write request has finished (to handle the next request)
 * - immediately after the socket opens to handle any pending requests
 * 
 * This method also handles auto-disconnect post read/write completion.
**/
- (void)maybeDequeueWrite
{
	LogTrace();
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	
	
	if ((currentWrite == nil) && (flags & kConnected))
	{
		if ([writeQueue count] > 0)
		{
			
			currentWrite = [writeQueue objectAtIndex:0];
			[writeQueue removeObjectAtIndex:0];
			
			
			if ([currentWrite isKindOfClass:[GCDAsyncSpecialPacket class]])
			{
				LogVerbose(@"Dequeued GCDAsyncSpecialPacket");
				
				
				flags |= kStartingWriteTLS;
				
				
				[self maybeStartTLS];
			}
			else
			{
				LogVerbose(@"Dequeued GCDAsyncWritePacket");
				
				
				[self setupWriteTimerWithTimeout:currentWrite->timeout];
				
				
				[self doWriteData];
			}
		}
		else if (flags & kDisconnectAfterWrites)
		{
			if (flags & kDisconnectAfterReads)
			{
				if (([readQueue count] == 0) && (currentRead == nil))
				{
					[self closeWithError:nil];
				}
			}
			else
			{
				[self closeWithError:nil];
			}
		}
	}
}

- (void)doWriteData
{
	LogTrace();
	
	
	
	if ((currentWrite == nil) || (flags & kWritesPaused))
	{
		LogVerbose(@"No currentWrite or kWritesPaused");
		
		
		
		if ([self usingCFStreamForTLS])
		{
			
			
		}
		else
		{
			
			
			
			if (flags & kSocketCanAcceptBytes)
			{
				[self suspendWriteSource];
			}
		}
		return;
	}
	
	if (!(flags & kSocketCanAcceptBytes))
	{
		LogVerbose(@"No space available to write...");
		
		
		
		if (![self usingCFStreamForTLS])
		{
			
			
			
			[self resumeWriteSource];
		}
		return;
	}
	
	if (flags & kStartingWriteTLS)
	{
		LogVerbose(@"Waiting for SSL/TLS handshake to complete");
		
		
		
		if (flags & kStartingReadTLS)
		{
			if ([self usingSecureTransportForTLS])
			{
				#if SECURE_TRANSPORT_MAYBE_AVAILABLE
			
				
				
			
				[self ssl_continueSSLHandshake];
			
				#endif
			}
		}
		else
		{
			
			
			
			if (![self usingCFStreamForTLS])
			{
				
				
				[self suspendWriteSource];
			}
		}
		
		return;
	}
	
	
	
	BOOL waiting = NO;
	NSError *error = nil;
	size_t bytesWritten = 0;
	
	if (flags & kSocketSecure)
	{
		if ([self usingCFStreamForTLS])
		{
			#if TARGET_OS_IPHONE
			
			
			
			
			
			const uint8_t *buffer = (const uint8_t *)[currentWrite->buffer bytes] + currentWrite->bytesDone;
			
			NSUInteger bytesToWrite = [currentWrite->buffer length] - currentWrite->bytesDone;
			
			if (bytesToWrite > SIZE_MAX) 
			{
				bytesToWrite = SIZE_MAX;
			}
		
			CFIndex result = CFWriteStreamWrite(writeStream, buffer, (CFIndex)bytesToWrite);
			LogVerbose(@"CFWriteStreamWrite(%lu) = %li", (unsigned long)bytesToWrite, result);
		
			if (result < 0)
			{
				error = (__bridge_transfer NSError *)CFWriteStreamCopyError(writeStream);
			}
			else
			{
				bytesWritten = (size_t)result;
				
				
				
				
				waiting = YES;
			}
			
			#endif
		}
		else
		{
			#if SECURE_TRANSPORT_MAYBE_AVAILABLE
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			OSStatus result;
			
			BOOL hasCachedDataToWrite = (sslWriteCachedLength > 0);
			BOOL hasNewDataToWrite = YES;
			
			if (hasCachedDataToWrite)
			{
				size_t processed = 0;
				
				result = SSLWrite(sslContext, NULL, 0, &processed);
				
				if (result == noErr)
				{
					bytesWritten = sslWriteCachedLength;
					sslWriteCachedLength = 0;
					
					if ([currentWrite->buffer length] == (currentWrite->bytesDone + bytesWritten))
					{
						
						hasNewDataToWrite = NO;
					}
				}
				else
				{
					if (result == errSSLWouldBlock)
					{
						waiting = YES;
					}
					else
					{
						error = [self sslError:result];
					}
					
					
					hasNewDataToWrite = NO;
				}
			}
			
			if (hasNewDataToWrite)
			{
				const uint8_t *buffer = (const uint8_t *)[currentWrite->buffer bytes]
				                                        + currentWrite->bytesDone
				                                        + bytesWritten;
				
				NSUInteger bytesToWrite = [currentWrite->buffer length] - currentWrite->bytesDone - bytesWritten;
				
				if (bytesToWrite > SIZE_MAX) 
				{
					bytesToWrite = SIZE_MAX;
				}
				
				size_t bytesRemaining = bytesToWrite;
				
				BOOL keepLooping = YES;
				while (keepLooping)
				{
					const size_t sslMaxBytesToWrite = 32768;
					size_t sslBytesToWrite = MIN(bytesRemaining, sslMaxBytesToWrite);
					size_t sslBytesWritten = 0;
					
					result = SSLWrite(sslContext, buffer, sslBytesToWrite, &sslBytesWritten);
					
					if (result == noErr)
					{
						buffer += sslBytesWritten;
						bytesWritten += sslBytesWritten;
						bytesRemaining -= sslBytesWritten;
						
						keepLooping = (bytesRemaining > 0);
					}
					else
					{
						if (result == errSSLWouldBlock)
						{
							waiting = YES;
							sslWriteCachedLength = sslBytesToWrite;
						}
						else
						{
							error = [self sslError:result];
						}
						
						keepLooping = NO;
					}
					
				} 
				
			} 
		
			#endif
		}
	}
	else
	{
		
		
		
		
		int socketFD = (socket4FD == SOCKET_NULL) ? socket6FD : socket4FD;
		
		const uint8_t *buffer = (const uint8_t *)[currentWrite->buffer bytes] + currentWrite->bytesDone;
		
		NSUInteger bytesToWrite = [currentWrite->buffer length] - currentWrite->bytesDone;
		
		if (bytesToWrite > SIZE_MAX) 
		{
			bytesToWrite = SIZE_MAX;
		}
		
		ssize_t result = write(socketFD, buffer, (size_t)bytesToWrite);
		LogVerbose(@"wrote to socket = %zd", result);
		
		
		if (result < 0)
		{
			if (errno == EWOULDBLOCK)
			{
				waiting = YES;
			}
			else
			{
				error = [self errnoErrorWithReason:@"Error in write() function"];
			}
		}
		else
		{
			bytesWritten = result;
		}
	}
	
	
	
	
	
	
	
	
	
	
	if (waiting)
	{
		flags &= ~kSocketCanAcceptBytes;
		
		if (![self usingCFStreamForTLS])
		{
			[self resumeWriteSource];
		}
	}
	
	
	
	BOOL done = NO;
	
	if (bytesWritten > 0)
	{
		
		currentWrite->bytesDone += bytesWritten;
		LogVerbose(@"currentWrite->bytesDone = %lu", (unsigned long)currentWrite->bytesDone);
		
		
		done = (currentWrite->bytesDone == [currentWrite->buffer length]);
	}
	
	if (done)
	{
		[self completeCurrentWrite];
		
		if (!error)
		{
			[self maybeDequeueWrite];
		}
	}
	else
	{
		
		
		
		if (!waiting && !error)
		{
			
			
			flags &= ~kSocketCanAcceptBytes;
			
			if (![self usingCFStreamForTLS])
			{
				[self resumeWriteSource];
			}
		}
		
		if (bytesWritten > 0)
		{
			
			
			if (delegateQueue && [delegate respondsToSelector:@selector(socket:didWritePartialDataOfLength:tag:)])
			{
				__strong id theDelegate = delegate;
				long theWriteTag = currentWrite->tag;
				
				dispatch_async(delegateQueue, ^{ @autoreleasepool {
					
					[theDelegate socket:self didWritePartialDataOfLength:bytesWritten tag:theWriteTag];
				}});
			}
		}
	}
	
	
	
	if (error)
	{
		[self closeWithError:[self errnoErrorWithReason:@"Error in write() function"]];
	}
	
	
}

- (void)completeCurrentWrite
{
	LogTrace();
	
	NSAssert(currentWrite, @"Trying to complete current write when there is no current write.");
	
	
	if (delegateQueue && [delegate respondsToSelector:@selector(socket:didWriteDataWithTag:)])
	{
		__strong id theDelegate = delegate;
		long theWriteTag = currentWrite->tag;
		
		dispatch_async(delegateQueue, ^{ @autoreleasepool {
			
			[theDelegate socket:self didWriteDataWithTag:theWriteTag];
		}});
	}
	
	[self endCurrentWrite];
}

- (void)endCurrentWrite
{
	if (writeTimer)
	{
		dispatch_source_cancel(writeTimer);
		writeTimer = NULL;
	}
	
	currentWrite = nil;
}

- (void)setupWriteTimerWithTimeout:(NSTimeInterval)timeout
{
	if (timeout >= 0.0)
	{
		writeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, socketQueue);
		
		dispatch_source_set_event_handler(writeTimer, ^{ @autoreleasepool {
			
			[self doWriteTimeout];
		}});
		
		#if !OS_OBJECT_USE_OBJC
		dispatch_source_t theWriteTimer = writeTimer;
		dispatch_source_set_cancel_handler(writeTimer, ^{
			LogVerbose(@"dispatch_release(writeTimer)");
			dispatch_release(theWriteTimer);
		});
		#endif
		
		dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
		
		dispatch_source_set_timer(writeTimer, tt, DISPATCH_TIME_FOREVER, 0);
		dispatch_resume(writeTimer);
	}
}

- (void)doWriteTimeout
{
	
	
	
	
	
	flags |= kWritesPaused;
	
	if (delegateQueue && [delegate respondsToSelector:@selector(socket:shouldTimeoutWriteWithTag:elapsed:bytesDone:)])
	{
		__strong id theDelegate = delegate;
		GCDAsyncWritePacket *theWrite = currentWrite;
		
		dispatch_async(delegateQueue, ^{ @autoreleasepool {
			
			NSTimeInterval timeoutExtension = 0.0;
			
			timeoutExtension = [theDelegate socket:self shouldTimeoutWriteWithTag:theWrite->tag
			                                                              elapsed:theWrite->timeout
			                                                            bytesDone:theWrite->bytesDone];
			
			dispatch_async(socketQueue, ^{ @autoreleasepool {
				
				[self doWriteTimeoutWithExtension:timeoutExtension];
			}});
		}});
	}
	else
	{
		[self doWriteTimeoutWithExtension:0.0];
	}
}

- (void)doWriteTimeoutWithExtension:(NSTimeInterval)timeoutExtension
{
	if (currentWrite)
	{
		if (timeoutExtension > 0.0)
		{
			currentWrite->timeout += timeoutExtension;
			
			
			dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutExtension * NSEC_PER_SEC));
			dispatch_source_set_timer(writeTimer, tt, DISPATCH_TIME_FOREVER, 0);
			
			
			flags &= ~kWritesPaused;
			[self doWriteData];
		}
		else
		{
			LogVerbose(@"WriteTimeout");
			
			[self closeWithError:[self writeTimeoutError]];
		}
	}
}


#pragma mark Security


- (void)startTLS:(NSDictionary *)tlsSettings
{
	LogTrace();
	
	if (tlsSettings == nil)
    {
        
        
        
        
        
        
        
        
        tlsSettings = [NSDictionary dictionary];
    }
	
	GCDAsyncSpecialPacket *packet = [[GCDAsyncSpecialPacket alloc] initWithTLSSettings:tlsSettings];
	
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
		if ((flags & kSocketStarted) && !(flags & kQueuedTLS) && !(flags & kForbidReadsWrites))
		{
			[readQueue addObject:packet];
			[writeQueue addObject:packet];
			
			flags |= kQueuedTLS;
			
			[self maybeDequeueRead];
			[self maybeDequeueWrite];
		}
	}});
	
}

- (void)maybeStartTLS
{
	
	
	
	
	
	
	if ((flags & kStartingReadTLS) && (flags & kStartingWriteTLS))
	{
		BOOL canUseSecureTransport = YES;
		
		#if TARGET_OS_IPHONE
		{
			GCDAsyncSpecialPacket *tlsPacket = (GCDAsyncSpecialPacket *)currentRead;
			NSDictionary *tlsSettings = tlsPacket->tlsSettings;
			
			NSNumber *value;
			
			value = [tlsSettings objectForKey:(NSString *)kCFStreamSSLAllowsAnyRoot];
			if (value && [value boolValue] == YES)
				canUseSecureTransport = NO;
			
			value = [tlsSettings objectForKey:(NSString *)kCFStreamSSLAllowsExpiredRoots];
			if (value && [value boolValue] == YES)
				canUseSecureTransport = NO;
			
			value = [tlsSettings objectForKey:(NSString *)kCFStreamSSLValidatesCertificateChain];
			if (value && [value boolValue] == NO)
				canUseSecureTransport = NO;
			
			value = [tlsSettings objectForKey:(NSString *)kCFStreamSSLAllowsExpiredCertificates];
			if (value && [value boolValue] == YES)
				canUseSecureTransport = NO;
		}
		#endif
		
		if (IS_SECURE_TRANSPORT_AVAILABLE && canUseSecureTransport)
		{
		#if SECURE_TRANSPORT_MAYBE_AVAILABLE
			[self ssl_startTLS];
		#endif
		}
		else
		{
		#if TARGET_OS_IPHONE
			[self cf_startTLS];
		#endif
		}
	}
}


#pragma mark Security via SecureTransport


#if SECURE_TRANSPORT_MAYBE_AVAILABLE

- (OSStatus)sslReadWithBuffer:(void *)buffer length:(size_t *)bufferLength
{
	LogVerbose(@"sslReadWithBuffer:%p length:%lu", buffer, (unsigned long)*bufferLength);
	
	if ((socketFDBytesAvailable == 0) && ([sslPreBuffer availableBytes] == 0))
	{
		LogVerbose(@"%@ - No data available to read...", THIS_METHOD);
		
		
		
		
		
		
		[self resumeReadSource];
		
		*bufferLength = 0;
		return errSSLWouldBlock;
	}
	
	size_t totalBytesRead = 0;
	size_t totalBytesLeftToBeRead = *bufferLength;
	
	BOOL done = NO;
	BOOL socketError = NO;
	
	
	
	
	
	size_t sslPreBufferLength = [sslPreBuffer availableBytes];
	
	if (sslPreBufferLength > 0)
	{
		LogVerbose(@"%@: Reading from SSL pre buffer...", THIS_METHOD);
		
		size_t bytesToCopy;
		if (sslPreBufferLength > totalBytesLeftToBeRead)
			bytesToCopy = totalBytesLeftToBeRead;
		else
			bytesToCopy = sslPreBufferLength;
		
		LogVerbose(@"%@: Copying %zu bytes from sslPreBuffer", THIS_METHOD, bytesToCopy);
		
		memcpy(buffer, [sslPreBuffer readBuffer], bytesToCopy);
		[sslPreBuffer didRead:bytesToCopy];
		
		LogVerbose(@"%@: sslPreBuffer.length = %zu", THIS_METHOD, [sslPreBuffer availableBytes]);
		
		totalBytesRead += bytesToCopy;
		totalBytesLeftToBeRead -= bytesToCopy;
		
		done = (totalBytesLeftToBeRead == 0);
		
		if (done) LogVerbose(@"%@: Complete", THIS_METHOD);
	}
	
	
	
	
	
	if (!done && (socketFDBytesAvailable > 0))
	{
		LogVerbose(@"%@: Reading from socket...", THIS_METHOD);
		
		int socketFD = (socket6FD == SOCKET_NULL) ? socket4FD : socket6FD;
		
		BOOL readIntoPreBuffer;
		size_t bytesToRead;
		uint8_t *buf;
		
		if (socketFDBytesAvailable > totalBytesLeftToBeRead)
		{
			
			
			
			LogVerbose(@"%@: Reading into sslPreBuffer...", THIS_METHOD);
			
			[sslPreBuffer ensureCapacityForWrite:socketFDBytesAvailable];
			
			readIntoPreBuffer = YES;
			bytesToRead = (size_t)socketFDBytesAvailable;
			buf = [sslPreBuffer writeBuffer];
		}
		else
		{
			
			
			LogVerbose(@"%@: Reading directly into dataBuffer...", THIS_METHOD);
			
			readIntoPreBuffer = NO;
			bytesToRead = totalBytesLeftToBeRead;
			buf = (uint8_t *)buffer + totalBytesRead;
		}
		
		ssize_t result = read(socketFD, buf, bytesToRead);
		LogVerbose(@"%@: read from socket = %zd", THIS_METHOD, result);
		
		if (result < 0)
		{
			LogVerbose(@"%@: read errno = %i", THIS_METHOD, errno);
			
			if (errno != EWOULDBLOCK)
			{
				socketError = YES;
			}
			
			socketFDBytesAvailable = 0;
		}
		else if (result == 0)
		{
			LogVerbose(@"%@: read EOF", THIS_METHOD);
			
			socketError = YES;
			socketFDBytesAvailable = 0;
		}
		else
		{
			size_t bytesReadFromSocket = result;
			
			if (socketFDBytesAvailable > bytesReadFromSocket)
				socketFDBytesAvailable -= bytesReadFromSocket;
			else
				socketFDBytesAvailable = 0;
			
			if (readIntoPreBuffer)
			{
				[sslPreBuffer didWrite:bytesReadFromSocket];
				
				size_t bytesToCopy = MIN(totalBytesLeftToBeRead, bytesReadFromSocket);
				
				LogVerbose(@"%@: Copying %zu bytes out of sslPreBuffer", THIS_METHOD, bytesToCopy);
				
				memcpy((uint8_t *)buffer + totalBytesRead, [sslPreBuffer readBuffer], bytesToCopy);
				[sslPreBuffer didRead:bytesToCopy];
				
				totalBytesRead += bytesToCopy;
				totalBytesLeftToBeRead -= bytesToCopy;
				
				LogVerbose(@"%@: sslPreBuffer.length = %zu", THIS_METHOD, [sslPreBuffer availableBytes]);
			}
			else
			{
				totalBytesRead += bytesReadFromSocket;
				totalBytesLeftToBeRead -= bytesReadFromSocket;
			}
			
			done = (totalBytesLeftToBeRead == 0);
			
			if (done) LogVerbose(@"%@: Complete", THIS_METHOD);
		}
	}
	
	*bufferLength = totalBytesRead;
	
	if (done)
		return noErr;
	
	if (socketError)
		return errSSLClosedAbort;
	
	return errSSLWouldBlock;
}

- (OSStatus)sslWriteWithBuffer:(const void *)buffer length:(size_t *)bufferLength
{
	if (!(flags & kSocketCanAcceptBytes))
	{
		
		
		
		
		
		[self resumeWriteSource];
		
		*bufferLength = 0;
		return errSSLWouldBlock;
	}
	
	size_t bytesToWrite = *bufferLength;
	size_t bytesWritten = 0;
	
	BOOL done = NO;
	BOOL socketError = NO;
	
	int socketFD = (socket4FD == SOCKET_NULL) ? socket6FD : socket4FD;
	
	ssize_t result = write(socketFD, buffer, bytesToWrite);
	
	if (result < 0)
	{
		if (errno != EWOULDBLOCK)
		{
			socketError = YES;
		}
		
		flags &= ~kSocketCanAcceptBytes;
	}
	else if (result == 0)
	{
		flags &= ~kSocketCanAcceptBytes;
	}
	else
	{
		bytesWritten = result;
		
		done = (bytesWritten == bytesToWrite);
	}
	
	*bufferLength = bytesWritten;
	
	if (done)
		return noErr;
	
	if (socketError)
		return errSSLClosedAbort;
	
	return errSSLWouldBlock;
}

static OSStatus SSLReadFunction(SSLConnectionRef connection, void *data, size_t *dataLength)
{
	GCDAsyncSocket *asyncSocket = (__bridge GCDAsyncSocket *)connection;
	
	NSCAssert(dispatch_get_specific(asyncSocket->IsOnSocketQueueOrTargetQueueKey), @"What the deuce?");
	
	return [asyncSocket sslReadWithBuffer:data length:dataLength];
}

static OSStatus SSLWriteFunction(SSLConnectionRef connection, const void *data, size_t *dataLength)
{
	GCDAsyncSocket *asyncSocket = (__bridge GCDAsyncSocket *)connection;
	
	NSCAssert(dispatch_get_specific(asyncSocket->IsOnSocketQueueOrTargetQueueKey), @"What the deuce?");
	
	return [asyncSocket sslWriteWithBuffer:data length:dataLength];
}

- (void)ssl_startTLS
{
	LogTrace();
	
	LogVerbose(@"Starting TLS (via SecureTransport)...");
		
	OSStatus status;
	
	GCDAsyncSpecialPacket *tlsPacket = (GCDAsyncSpecialPacket *)currentRead;
	NSDictionary *tlsSettings = tlsPacket->tlsSettings;
	
	
	
	BOOL isServer = [[tlsSettings objectForKey:(NSString *)kCFStreamSSLIsServer] boolValue];
	
	#if TARGET_OS_IPHONE
	{
		if (isServer)
			sslContext = SSLCreateContext(kCFAllocatorDefault, kSSLServerSide, kSSLStreamType);
		else
			sslContext = SSLCreateContext(kCFAllocatorDefault, kSSLClientSide, kSSLStreamType);
		
		if (sslContext == NULL)
		{
			[self closeWithError:[self otherError:@"Error in SSLCreateContext"]];
			return;
		}
	}
	#else
	{
		status = SSLNewContext(isServer, &sslContext);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLNewContext"]];
			return;
		}
	}
	#endif
	
	status = SSLSetIOFuncs(sslContext, &SSLReadFunction, &SSLWriteFunction);
	if (status != noErr)
	{
		[self closeWithError:[self otherError:@"Error in SSLSetIOFuncs"]];
		return;
	}
	
	status = SSLSetConnection(sslContext, (__bridge SSLConnectionRef)self);
	if (status != noErr)
	{
		[self closeWithError:[self otherError:@"Error in SSLSetConnection"]];
		return;
	}
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	id value;
	
	
	
	value = [tlsSettings objectForKey:(NSString *)kCFStreamSSLPeerName];
	if ([value isKindOfClass:[NSString class]])
	{
		NSString *peerName = (NSString *)value;
		
		const char *peer = [peerName UTF8String];
		size_t peerLen = strlen(peer);
		
		status = SSLSetPeerDomainName(sslContext, peer, peerLen);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetPeerDomainName"]];
			return;
		}
	}
	
	
	
	value = [tlsSettings objectForKey:(NSString *)kCFStreamSSLAllowsAnyRoot];
	if (value)
	{
		#if TARGET_OS_IPHONE
		NSAssert(NO, @"Security option unavailable via SecureTransport in iOS - kCFStreamSSLAllowsAnyRoot");
		#else
		
		BOOL allowsAnyRoot = [value boolValue];
		
		status = SSLSetAllowsAnyRoot(sslContext, allowsAnyRoot);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetAllowsAnyRoot"]];
			return;
		}
		
		#endif
	}
	
	
	
	value = [tlsSettings objectForKey:(NSString *)kCFStreamSSLAllowsExpiredRoots];
	if (value)
	{
		#if TARGET_OS_IPHONE
		NSAssert(NO, @"Security option unavailable via SecureTransport in iOS - kCFStreamSSLAllowsExpiredRoots");
		#else
		
		BOOL allowsExpiredRoots = [value boolValue];
		
		status = SSLSetAllowsExpiredRoots(sslContext, allowsExpiredRoots);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetAllowsExpiredRoots"]];
			return;
		}
		
		#endif
	}
	
	
	
	value = [tlsSettings objectForKey:(NSString *)kCFStreamSSLValidatesCertificateChain];
	if (value)
	{
		#if TARGET_OS_IPHONE
		NSAssert(NO, @"Security option unavailable via SecureTransport in iOS - kCFStreamSSLValidatesCertificateChain");
		#else
		
		BOOL validatesCertChain = [value boolValue];
		
		status = SSLSetEnableCertVerify(sslContext, validatesCertChain);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetEnableCertVerify"]];
			return;
		}
		
		#endif
	}
	
	
	
	value = [tlsSettings objectForKey:(NSString *)kCFStreamSSLAllowsExpiredCertificates];
	if (value)
	{
		#if TARGET_OS_IPHONE
		NSAssert(NO, @"Security option unavailable via SecureTransport in iOS - kCFStreamSSLAllowsExpiredCertificates");
		#else
		
		BOOL allowsExpiredCerts = [value boolValue];
		
		status = SSLSetAllowsExpiredCerts(sslContext, allowsExpiredCerts);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetAllowsExpiredCerts"]];
			return;
		}
		
		#endif
	}
	
	
	
	value = [tlsSettings objectForKey:(NSString *)kCFStreamSSLCertificates];
	if (value)
	{
		CFArrayRef certs = (__bridge CFArrayRef)value;
		
		status = SSLSetCertificate(sslContext, certs);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetCertificate"]];
			return;
		}
	}
	
	
	
	#if TARGET_OS_IPHONE
	{
		NSString *sslLevel = [tlsSettings objectForKey:(NSString *)kCFStreamSSLLevel];
		
		NSString *sslMinLevel = [tlsSettings objectForKey:GCDAsyncSocketSSLProtocolVersionMin];
		NSString *sslMaxLevel = [tlsSettings objectForKey:GCDAsyncSocketSSLProtocolVersionMax];
		
		if (sslLevel)
		{
			if (sslMinLevel || sslMaxLevel)
			{
				LogWarn(@"kCFStreamSSLLevel security option ignored. Overriden by "
						@"GCDAsyncSocketSSLProtocolVersionMin and/or GCDAsyncSocketSSLProtocolVersionMax");
			}
			else
			{
				if ([sslLevel isEqualToString:(NSString *)kCFStreamSocketSecurityLevelSSLv3])
				{
					sslMinLevel = sslMaxLevel = @"kSSLProtocol3";
				}
				else if ([sslLevel isEqualToString:(NSString *)kCFStreamSocketSecurityLevelTLSv1])
				{
					sslMinLevel = sslMaxLevel = @"kTLSProtocol1";
				}
				else
				{
					LogWarn(@"Unable to match kCFStreamSSLLevel security option to valid SSL protocol min/max");
				}
			}
		}
		
		if (sslMinLevel || sslMaxLevel)
		{
			OSStatus status1 = noErr;
			OSStatus status2 = noErr;
			
			SSLProtocol (^sslProtocolForString)(NSString*) = ^SSLProtocol (NSString *protocolStr) {
				
				if ([protocolStr isEqualToString:@"kSSLProtocol3"])  return kSSLProtocol3;
				if ([protocolStr isEqualToString:@"kTLSProtocol1"])  return kTLSProtocol1;
				if ([protocolStr isEqualToString:@"kTLSProtocol11"]) return kTLSProtocol11;
				if ([protocolStr isEqualToString:@"kTLSProtocol12"]) return kTLSProtocol12;
				
				return kSSLProtocolUnknown;
			};
			
			SSLProtocol minProtocol = sslProtocolForString(sslMinLevel);
			SSLProtocol maxProtocol = sslProtocolForString(sslMaxLevel);
			
			if (minProtocol != kSSLProtocolUnknown)
			{
				status1 = SSLSetProtocolVersionMin(sslContext, minProtocol);
			}
			if (maxProtocol != kSSLProtocolUnknown)
			{
				status2 = SSLSetProtocolVersionMax(sslContext, maxProtocol);
			}
			
			if (status1 != noErr || status2 != noErr)
			{
				[self closeWithError:[self otherError:@"Error in SSLSetProtocolVersionMinMax"]];
				return;
			}
		}
	}
	#else
	{
		value = [tlsSettings objectForKey:(NSString *)kCFStreamSSLLevel];
		if (value)
		{
			NSString *sslLevel = (NSString *)value;
			
			OSStatus status1 = noErr;
			OSStatus status2 = noErr;
			OSStatus status3 = noErr;
			
			if ([sslLevel isEqualToString:(NSString *)kCFStreamSocketSecurityLevelSSLv2])
			{
				
				
				
				
				status1 = SSLSetProtocolVersionEnabled(sslContext, kSSLProtocolAll, NO);
				status2 = SSLSetProtocolVersionEnabled(sslContext, kSSLProtocol2,   YES);
			}
			else if ([sslLevel isEqualToString:(NSString *)kCFStreamSocketSecurityLevelSSLv3])
			{
				
				
				
				
				
				status1 = SSLSetProtocolVersionEnabled(sslContext, kSSLProtocolAll, NO);
				status2 = SSLSetProtocolVersionEnabled(sslContext, kSSLProtocol2,   YES);
				status3 = SSLSetProtocolVersionEnabled(sslContext, kSSLProtocol3,   YES);
			}
			else if ([sslLevel isEqualToString:(NSString *)kCFStreamSocketSecurityLevelTLSv1])
			{
				
				
				
				
				status1 = SSLSetProtocolVersionEnabled(sslContext, kSSLProtocolAll, NO);
				status2 = SSLSetProtocolVersionEnabled(sslContext, kTLSProtocol1,   YES);
			}
			else if ([sslLevel isEqualToString:(NSString *)kCFStreamSocketSecurityLevelNegotiatedSSL])
			{
				
				
				
				
				status1 = SSLSetProtocolVersionEnabled(sslContext, kSSLProtocolAll, YES);
			}
			
			if (status1 != noErr || status2 != noErr || status3 != noErr)
			{
				[self closeWithError:[self otherError:@"Error in SSLSetProtocolVersionEnabled"]];
				return;
			}
		}
	}
	#endif
	
	
	
	value = [tlsSettings objectForKey:GCDAsyncSocketSSLCipherSuites];
	if (value)
	{
		NSArray *cipherSuites = (NSArray *)value;
		NSUInteger numberCiphers = [cipherSuites count];
		SSLCipherSuite ciphers[numberCiphers];
		
		NSUInteger cipherIndex;
		for (cipherIndex = 0; cipherIndex < numberCiphers; cipherIndex++)
		{
			NSNumber *cipherObject = [cipherSuites objectAtIndex:cipherIndex];
			ciphers[cipherIndex] = [cipherObject shortValue];
		}
		
		status = SSLSetEnabledCiphers(sslContext, ciphers, numberCiphers);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetEnabledCiphers"]];
			return;
		}
	}
	
	
	
	#if !TARGET_OS_IPHONE
	value = [tlsSettings objectForKey:GCDAsyncSocketSSLDiffieHellmanParameters];
	if (value)
	{
		NSData *diffieHellmanData = (NSData *)value;
		
		status = SSLSetDiffieHellmanParams(sslContext, [diffieHellmanData bytes], [diffieHellmanData length]);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetDiffieHellmanParams"]];
			return;
		}
	}
	#endif
	
	
	
	
	
	
	sslPreBuffer = [[GCDAsyncSocketPreBuffer alloc] initWithCapacity:(1024 * 4)];
	
	size_t preBufferLength  = [preBuffer availableBytes];
	
	if (preBufferLength > 0)
	{
		[sslPreBuffer ensureCapacityForWrite:preBufferLength];
		
		memcpy([sslPreBuffer writeBuffer], [preBuffer readBuffer], preBufferLength);
		[preBuffer didRead:preBufferLength];
		[sslPreBuffer didWrite:preBufferLength];
	}
	
	sslErrCode = noErr;
	
	
	
	[self ssl_continueSSLHandshake];
}

- (void)ssl_continueSSLHandshake
{
	LogTrace();
	
	
	
	
	
	OSStatus status = SSLHandshake(sslContext);
	
	if (status == noErr)
	{
		LogVerbose(@"SSLHandshake complete");
		
		flags &= ~kStartingReadTLS;
		flags &= ~kStartingWriteTLS;
		
		flags |=  kSocketSecure;
		
		if (delegateQueue && [delegate respondsToSelector:@selector(socketDidSecure:)])
		{
			__strong id theDelegate = delegate;
			
			dispatch_async(delegateQueue, ^{ @autoreleasepool {
				
				[theDelegate socketDidSecure:self];
			}});
		}
		
		[self endCurrentRead];
		[self endCurrentWrite];
		
		[self maybeDequeueRead];
		[self maybeDequeueWrite];
	}
	else if (status == errSSLWouldBlock)
	{
		LogVerbose(@"SSLHandshake continues...");
		
		
		
		
	}
	else
	{
		[self closeWithError:[self sslError:status]];
	}
}

#endif


#pragma mark Security via CFStream


#if TARGET_OS_IPHONE

- (void)cf_finishSSLHandshake
{
	LogTrace();
	
	if ((flags & kStartingReadTLS) && (flags & kStartingWriteTLS))
	{
		flags &= ~kStartingReadTLS;
		flags &= ~kStartingWriteTLS;
		
		flags |= kSocketSecure;
		
		if (delegateQueue && [delegate respondsToSelector:@selector(socketDidSecure:)])
		{
			__strong id theDelegate = delegate;
		
			dispatch_async(delegateQueue, ^{ @autoreleasepool {
				
				[theDelegate socketDidSecure:self];
			}});
		}
		
		[self endCurrentRead];
		[self endCurrentWrite];
		
		[self maybeDequeueRead];
		[self maybeDequeueWrite];
	}
}

- (void)cf_abortSSLHandshake:(NSError *)error
{
	LogTrace();
	
	if ((flags & kStartingReadTLS) && (flags & kStartingWriteTLS))
	{
		flags &= ~kStartingReadTLS;
		flags &= ~kStartingWriteTLS;
		
		[self closeWithError:error];
	}
}

- (void)cf_startTLS
{
	LogTrace();
	
	LogVerbose(@"Starting TLS (via CFStream)...");
	
	if ([preBuffer availableBytes] > 0)
	{
		NSString *msg = @"Invalid TLS transition. Handshake has already been read from socket.";
		
		[self closeWithError:[self otherError:msg]];
		return;
	}
	
	[self suspendReadSource];
	[self suspendWriteSource];
	
	socketFDBytesAvailable = 0;
	flags &= ~kSocketCanAcceptBytes;
	flags &= ~kSecureSocketHasBytesAvailable;
	
	flags |=  kUsingCFStreamForTLS;
	
	if (![self createReadAndWriteStream])
	{
		[self closeWithError:[self otherError:@"Error in CFStreamCreatePairWithSocket"]];
		return;
	}
	
	if (![self registerForStreamCallbacksIncludingReadWrite:YES])
	{
		[self closeWithError:[self otherError:@"Error in CFStreamSetClient"]];
		return;
	}
	
	if (![self addStreamsToRunLoop])
	{
		[self closeWithError:[self otherError:@"Error in CFStreamScheduleWithRunLoop"]];
		return;
	}
	
	NSAssert([currentRead isKindOfClass:[GCDAsyncSpecialPacket class]], @"Invalid read packet for startTLS");
	NSAssert([currentWrite isKindOfClass:[GCDAsyncSpecialPacket class]], @"Invalid write packet for startTLS");
	
	GCDAsyncSpecialPacket *tlsPacket = (GCDAsyncSpecialPacket *)currentRead;
	CFDictionaryRef tlsSettings = (__bridge CFDictionaryRef)tlsPacket->tlsSettings;
	
	
	
	
	BOOL r1 = CFReadStreamSetProperty(readStream, kCFStreamPropertySSLSettings, tlsSettings);
	BOOL r2 = CFWriteStreamSetProperty(writeStream, kCFStreamPropertySSLSettings, tlsSettings);
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	if (!r1 && !r2) 
	{
		[self closeWithError:[self otherError:@"Error in CFStreamSetProperty"]];
		return;
	}
	
	if (![self openStreams])
	{
		[self closeWithError:[self otherError:@"Error in CFStreamOpen"]];
		return;
	}
	
	LogVerbose(@"Waiting for SSL Handshake to complete...");
}

#endif


#pragma mark CFStream


#if TARGET_OS_IPHONE

+ (void)ignore:(id)_
{}

+ (void)startCFStreamThreadIfNeeded
{
	static dispatch_once_t predicate;
	dispatch_once(&predicate, ^{
		
		cfstreamThread = [[NSThread alloc] initWithTarget:self
		                                         selector:@selector(cfstreamThread)
		                                           object:nil];
		[cfstreamThread start];
	});
}

+ (void)cfstreamThread { @autoreleasepool
{
	[[NSThread currentThread] setName:GCDAsyncSocketThreadName];
	
	LogInfo(@"CFStreamThread: Started");
	
	
	
	[NSTimer scheduledTimerWithTimeInterval:[[NSDate distantFuture] timeIntervalSinceNow]
	                                 target:self
	                               selector:@selector(ignore:)
	                               userInfo:nil
	                                repeats:YES];
	
	[[NSRunLoop currentRunLoop] run];
	
	LogInfo(@"CFStreamThread: Stopped");
}}

+ (void)scheduleCFStreams:(GCDAsyncSocket *)asyncSocket
{
	LogTrace();
	NSAssert([NSThread currentThread] == cfstreamThread, @"Invoked on wrong thread");
	
	CFRunLoopRef runLoop = CFRunLoopGetCurrent();
	
	if (asyncSocket->readStream)
		CFReadStreamScheduleWithRunLoop(asyncSocket->readStream, runLoop, kCFRunLoopDefaultMode);
	
	if (asyncSocket->writeStream)
		CFWriteStreamScheduleWithRunLoop(asyncSocket->writeStream, runLoop, kCFRunLoopDefaultMode);
}

+ (void)unscheduleCFStreams:(GCDAsyncSocket *)asyncSocket
{
	LogTrace();
	NSAssert([NSThread currentThread] == cfstreamThread, @"Invoked on wrong thread");
	
	CFRunLoopRef runLoop = CFRunLoopGetCurrent();
	
	if (asyncSocket->readStream)
		CFReadStreamUnscheduleFromRunLoop(asyncSocket->readStream, runLoop, kCFRunLoopDefaultMode);
	
	if (asyncSocket->writeStream)
		CFWriteStreamUnscheduleFromRunLoop(asyncSocket->writeStream, runLoop, kCFRunLoopDefaultMode);
}

static void CFReadStreamCallback (CFReadStreamRef stream, CFStreamEventType type, void *pInfo)
{
	GCDAsyncSocket *asyncSocket = (__bridge GCDAsyncSocket *)pInfo;
	
	switch(type)
	{
		case kCFStreamEventHasBytesAvailable:
		{
			dispatch_async(asyncSocket->socketQueue, ^{ @autoreleasepool {
				
				LogCVerbose(@"CFReadStreamCallback - HasBytesAvailable");
				
				if (asyncSocket->readStream != stream)
					return_from_block;
				
				if ((asyncSocket->flags & kStartingReadTLS) && (asyncSocket->flags & kStartingWriteTLS))
				{
					
					
					
					if (CFReadStreamHasBytesAvailable(asyncSocket->readStream))
					{
						asyncSocket->flags |= kSecureSocketHasBytesAvailable;
						[asyncSocket cf_finishSSLHandshake];
					}
				}
				else
				{
					asyncSocket->flags |= kSecureSocketHasBytesAvailable;
					[asyncSocket doReadData];
				}
			}});
			
			break;
		}
		default:
		{
			NSError *error = (__bridge_transfer  NSError *)CFReadStreamCopyError(stream);
			
			if (error == nil && type == kCFStreamEventEndEncountered)
			{
				error = [asyncSocket connectionClosedError];
			}
			
			dispatch_async(asyncSocket->socketQueue, ^{ @autoreleasepool {
				
				LogCVerbose(@"CFReadStreamCallback - Other");
				
				if (asyncSocket->readStream != stream)
					return_from_block;
				
				if ((asyncSocket->flags & kStartingReadTLS) && (asyncSocket->flags & kStartingWriteTLS))
				{
					[asyncSocket cf_abortSSLHandshake:error];
				}
				else
				{
					[asyncSocket closeWithError:error];
				}
			}});
			
			break;
		}
	}
	
}

static void CFWriteStreamCallback (CFWriteStreamRef stream, CFStreamEventType type, void *pInfo)
{
	GCDAsyncSocket *asyncSocket = (__bridge GCDAsyncSocket *)pInfo;
	
	switch(type)
	{
		case kCFStreamEventCanAcceptBytes:
		{
			dispatch_async(asyncSocket->socketQueue, ^{ @autoreleasepool {
				
				LogCVerbose(@"CFWriteStreamCallback - CanAcceptBytes");
				
				if (asyncSocket->writeStream != stream)
					return_from_block;
				
				if ((asyncSocket->flags & kStartingReadTLS) && (asyncSocket->flags & kStartingWriteTLS))
				{
					
					
					
					if (CFWriteStreamCanAcceptBytes(asyncSocket->writeStream))
					{
						asyncSocket->flags |= kSocketCanAcceptBytes;
						[asyncSocket cf_finishSSLHandshake];
					}
				}
				else
				{
					asyncSocket->flags |= kSocketCanAcceptBytes;
					[asyncSocket doWriteData];
				}
			}});
			
			break;
		}
		default:
		{
			NSError *error = (__bridge_transfer NSError *)CFWriteStreamCopyError(stream);
			
			if (error == nil && type == kCFStreamEventEndEncountered)
			{
				error = [asyncSocket connectionClosedError];
			}
			
			dispatch_async(asyncSocket->socketQueue, ^{ @autoreleasepool {
				
				LogCVerbose(@"CFWriteStreamCallback - Other");
				
				if (asyncSocket->writeStream != stream)
					return_from_block;
				
				if ((asyncSocket->flags & kStartingReadTLS) && (asyncSocket->flags & kStartingWriteTLS))
				{
					[asyncSocket cf_abortSSLHandshake:error];
				}
				else
				{
					[asyncSocket closeWithError:error];
				}
			}});
			
			break;
		}
	}
	
}

- (BOOL)createReadAndWriteStream
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	
	if (readStream || writeStream)
	{
		
		return YES;
	}
	
	int socketFD = (socket6FD == SOCKET_NULL) ? socket4FD : socket6FD;
	
	if (socketFD == SOCKET_NULL)
	{
		
		return NO;
	}
	
	if (![self isConnected])
	{
		
		return NO;
	}
	
	LogVerbose(@"Creating read and write stream...");
	
	CFStreamCreatePairWithSocket(NULL, (CFSocketNativeHandle)socketFD, &readStream, &writeStream);
	
	
	
	
	if (readStream)
		CFReadStreamSetProperty(readStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanFalse);
	if (writeStream)
		CFWriteStreamSetProperty(writeStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanFalse);
	
	if ((readStream == NULL) || (writeStream == NULL))
	{
		LogWarn(@"Unable to create read and write stream...");
		
		if (readStream)
		{
			CFReadStreamClose(readStream);
			CFRelease(readStream);
			readStream = NULL;
		}
		if (writeStream)
		{
			CFWriteStreamClose(writeStream);
			CFRelease(writeStream);
			writeStream = NULL;
		}
		
		return NO;
	}
	
	return YES;
}

- (BOOL)registerForStreamCallbacksIncludingReadWrite:(BOOL)includeReadWrite
{
	LogVerbose(@"%@ %@", THIS_METHOD, (includeReadWrite ? @"YES" : @"NO"));
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	NSAssert((readStream != NULL && writeStream != NULL), @"Read/Write stream is null");
	
	streamContext.version = 0;
	streamContext.info = (__bridge void *)(self);
	streamContext.retain = nil;
	streamContext.release = nil;
	streamContext.copyDescription = nil;
	
	CFOptionFlags readStreamEvents = kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered;
	if (includeReadWrite)
		readStreamEvents |= kCFStreamEventHasBytesAvailable;
	
	if (!CFReadStreamSetClient(readStream, readStreamEvents, &CFReadStreamCallback, &streamContext))
	{
		return NO;
	}
	
	CFOptionFlags writeStreamEvents = kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered;
	if (includeReadWrite)
		writeStreamEvents |= kCFStreamEventCanAcceptBytes;
	
	if (!CFWriteStreamSetClient(writeStream, writeStreamEvents, &CFWriteStreamCallback, &streamContext))
	{
		return NO;
	}
	
	return YES;
}

- (BOOL)addStreamsToRunLoop
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	NSAssert((readStream != NULL && writeStream != NULL), @"Read/Write stream is null");
	
	if (!(flags & kAddedStreamsToRunLoop))
	{
		LogVerbose(@"Adding streams to runloop...");
		
		[[self class] startCFStreamThreadIfNeeded];
		[[self class] performSelector:@selector(scheduleCFStreams:)
		                     onThread:cfstreamThread
		                   withObject:self
		                waitUntilDone:YES];
		
		flags |= kAddedStreamsToRunLoop;
	}
	
	return YES;
}

- (void)removeStreamsFromRunLoop
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	NSAssert((readStream != NULL && writeStream != NULL), @"Read/Write stream is null");
	
	if (flags & kAddedStreamsToRunLoop)
	{
		LogVerbose(@"Removing streams from runloop...");
		
		[[self class] performSelector:@selector(unscheduleCFStreams:)
		                     onThread:cfstreamThread
		                   withObject:self
		                waitUntilDone:YES];
		
		flags &= ~kAddedStreamsToRunLoop;
	}
}

- (BOOL)openStreams
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	NSAssert((readStream != NULL && writeStream != NULL), @"Read/Write stream is null");
	
	CFStreamStatus readStatus = CFReadStreamGetStatus(readStream);
	CFStreamStatus writeStatus = CFWriteStreamGetStatus(writeStream);
	
	if ((readStatus == kCFStreamStatusNotOpen) || (writeStatus == kCFStreamStatusNotOpen))
	{
		LogVerbose(@"Opening read and write stream...");
		
		BOOL r1 = CFReadStreamOpen(readStream);
		BOOL r2 = CFWriteStreamOpen(writeStream);
		
		if (!r1 || !r2)
		{
			LogError(@"Error in CFStreamOpen");
			return NO;
		}
	}
	
	return YES;
}

#endif


#pragma mark Advanced


/**
 * See header file for big discussion of this method.
**/
- (void)performBlock:(dispatch_block_t)block
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
}

/**
 * Questions? Have you read the header file?
**/
- (int)socketFD
{
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return SOCKET_NULL;
	}
	
	if (socket4FD != SOCKET_NULL)
		return socket4FD;
	else
		return socket6FD;
}

/**
 * Questions? Have you read the header file?
**/
- (int)socket4FD
{
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return SOCKET_NULL;
	}
	
	return socket4FD;
}

/**
 * Questions? Have you read the header file?
**/
- (int)socket6FD
{
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return SOCKET_NULL;
	}
	
	return socket6FD;
}

#if TARGET_OS_IPHONE

/**
 * Questions? Have you read the header file?
**/
- (CFReadStreamRef)readStream
{
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return NULL;
	}
	
	if (readStream == NULL)
		[self createReadAndWriteStream];
	
	return readStream;
}

/**
 * Questions? Have you read the header file?
**/
- (CFWriteStreamRef)writeStream
{
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return NULL;
	}
	
	if (writeStream == NULL)
		[self createReadAndWriteStream];
	
	return writeStream;
}

- (BOOL)enableBackgroundingOnSocketWithCaveat:(BOOL)caveat
{
	if (![self createReadAndWriteStream])
	{
		
		return NO;
	}
	
	BOOL r1, r2;
	
	LogVerbose(@"Enabling backgrouding on socket");
	
	r1 = CFReadStreamSetProperty(readStream, kCFStreamNetworkServiceType, kCFStreamNetworkServiceTypeVoIP);
	r2 = CFWriteStreamSetProperty(writeStream, kCFStreamNetworkServiceType, kCFStreamNetworkServiceTypeVoIP);
	
	if (!r1 || !r2)
	{
		return NO;
	}
	
	if (!caveat)
	{
		if (![self openStreams])
		{
			return NO;
		}
	}
	
	return YES;
}

/**
 * Questions? Have you read the header file?
**/
- (BOOL)enableBackgroundingOnSocket
{
	LogTrace();
	
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return NO;
	}
	
	return [self enableBackgroundingOnSocketWithCaveat:NO];
}

- (BOOL)enableBackgroundingOnSocketWithCaveat 
{
	
	
	
	
	LogTrace();
	
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return NO;
	}
	
	return [self enableBackgroundingOnSocketWithCaveat:YES];
}

#endif

#if SECURE_TRANSPORT_MAYBE_AVAILABLE

- (SSLContextRef)sslContext
{
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return NULL;
	}
	
	return sslContext;
}

#endif


#pragma mark Class Methods


+ (NSString *)hostFromSockaddr4:(const struct sockaddr_in *)pSockaddr4
{
	char addrBuf[INET_ADDRSTRLEN];
	
	if (inet_ntop(AF_INET, &pSockaddr4->sin_addr, addrBuf, (socklen_t)sizeof(addrBuf)) == NULL)
	{
		addrBuf[0] = '\0';
	}
	
	return [NSString stringWithCString:addrBuf encoding:NSASCIIStringEncoding];
}

+ (NSString *)hostFromSockaddr6:(const struct sockaddr_in6 *)pSockaddr6
{
	char addrBuf[INET6_ADDRSTRLEN];
	
	if (inet_ntop(AF_INET6, &pSockaddr6->sin6_addr, addrBuf, (socklen_t)sizeof(addrBuf)) == NULL)
	{
		addrBuf[0] = '\0';
	}
	
	return [NSString stringWithCString:addrBuf encoding:NSASCIIStringEncoding];
}

+ (uint16_t)portFromSockaddr4:(const struct sockaddr_in *)pSockaddr4
{
	return ntohs(pSockaddr4->sin_port);
}

+ (uint16_t)portFromSockaddr6:(const struct sockaddr_in6 *)pSockaddr6
{
	return ntohs(pSockaddr6->sin6_port);
}

+ (NSString *)hostFromAddress:(NSData *)address
{
	NSString *host;
	
	if ([self getHost:&host port:NULL fromAddress:address])
		return host;
	else
		return nil;
}

+ (uint16_t)portFromAddress:(NSData *)address
{
	uint16_t port;
	
	if ([self getHost:NULL port:&port fromAddress:address])
		return port;
	else
		return 0;
}

+ (BOOL)getHost:(NSString **)hostPtr port:(uint16_t *)portPtr fromAddress:(NSData *)address
{
	if ([address length] >= sizeof(struct sockaddr))
	{
		const struct sockaddr *sockaddrX = [address bytes];
		
		if (sockaddrX->sa_family == AF_INET)
		{
			if ([address length] >= sizeof(struct sockaddr_in))
			{
				struct sockaddr_in sockaddr4;
				memcpy(&sockaddr4, sockaddrX, sizeof(sockaddr4));
				
				if (hostPtr) *hostPtr = [self hostFromSockaddr4:&sockaddr4];
				if (portPtr) *portPtr = [self portFromSockaddr4:&sockaddr4];
				
				return YES;
			}
		}
		else if (sockaddrX->sa_family == AF_INET6)
		{
			if ([address length] >= sizeof(struct sockaddr_in6))
			{
				struct sockaddr_in6 sockaddr6;
				memcpy(&sockaddr6, sockaddrX, sizeof(sockaddr6));
				
				if (hostPtr) *hostPtr = [self hostFromSockaddr6:&sockaddr6];
				if (portPtr) *portPtr = [self portFromSockaddr6:&sockaddr6];
				
				return YES;
			}
		}
	}
	
	return NO;
}

@end	
