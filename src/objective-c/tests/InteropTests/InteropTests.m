/*
 *
 * Copyright 2015 gRPC authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */

#import "InteropTests.h"

#include <grpc/status.h>

#ifdef GRPC_COMPILE_WITH_CRONET
#import <Cronet/Cronet.h>
#endif
#import <GRPCClient/GRPCCall+ChannelArg.h>
#import <GRPCClient/GRPCCall+Cronet.h>
#import <GRPCClient/GRPCCall+Tests.h>
#import <GRPCClient/GRPCInterceptor.h>
#import <GRPCClient/internal_testing/GRPCCall+InternalTests.h>
#import <ProtoRPC/ProtoRPC.h>
#import <RemoteTest/Messages.pbobjc.h>
#import <RemoteTest/Test.pbobjc.h>
#import <RemoteTest/Test.pbrpc.h>
#import <RxLibrary/GRXBufferedPipe.h>
#import <RxLibrary/GRXWriter+Immediate.h>
#import <grpc/grpc.h>
#import <grpc/support/log.h>

#import "../ConfigureCronet.h"
#import "InteropTestsBlockCallbacks.h"

#define TEST_TIMEOUT 32

extern const char *kCFStreamVarName;

// Convenience constructors for the generated proto messages:

@interface RMTStreamingOutputCallRequest (Constructors)
+ (instancetype)messageWithPayloadSize:(NSNumber *)payloadSize
                 requestedResponseSize:(NSNumber *)responseSize;
@end

@implementation RMTStreamingOutputCallRequest (Constructors)
+ (instancetype)messageWithPayloadSize:(NSNumber *)payloadSize
                 requestedResponseSize:(NSNumber *)responseSize {
  RMTStreamingOutputCallRequest *request = [self message];
  RMTResponseParameters *parameters = [RMTResponseParameters message];
  parameters.size = responseSize.intValue;
  [request.responseParametersArray addObject:parameters];
  request.payload.body = [NSMutableData dataWithLength:payloadSize.unsignedIntegerValue];
  return request;
}
@end

@interface RMTStreamingOutputCallResponse (Constructors)
+ (instancetype)messageWithPayloadSize:(NSNumber *)payloadSize;
@end

@implementation RMTStreamingOutputCallResponse (Constructors)
+ (instancetype)messageWithPayloadSize:(NSNumber *)payloadSize {
  RMTStreamingOutputCallResponse *response = [self message];
  response.payload.type = RMTPayloadType_Compressable;
  response.payload.body = [NSMutableData dataWithLength:payloadSize.unsignedIntegerValue];
  return response;
}
@end

BOOL isRemoteInteropTest(NSString *host) {
  return [host isEqualToString:@"grpc-test.sandbox.googleapis.com"];
}

@interface DefaultInterceptorFactory : NSObject<GRPCInterceptorFactory>

- (GRPCInterceptor *)createInterceptorWithManager:(GRPCInterceptorManager *)interceptorManager;

@end

@implementation DefaultInterceptorFactory

- (GRPCInterceptor *)createInterceptorWithManager:(GRPCInterceptorManager *)interceptorManager {
  dispatch_queue_t queue = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);
  return [[GRPCInterceptor alloc] initWithInterceptorManager:interceptorManager
                                        requestDispatchQueue:queue
                                       responseDispatchQueue:queue];
}

@end

@interface HookInterceptorFactory : NSObject<GRPCInterceptorFactory>

- (instancetype)
initWithRequestDispatchQueue:(dispatch_queue_t)requestDispatchQueue
       responseDispatchQueue:(dispatch_queue_t)responseDispatchQueue
                   startHook:(void (^)(GRPCRequestOptions *requestOptions,
                                       GRPCCallOptions *callOptions,
                                       GRPCInterceptorManager *manager))startHook
               writeDataHook:(void (^)(id data, GRPCInterceptorManager *manager))writeDataHook
                  finishHook:(void (^)(GRPCInterceptorManager *manager))finishHook
     receiveNextMessagesHook:(void (^)(NSUInteger numberOfMessages,
                                       GRPCInterceptorManager *manager))receiveNextMessagesHook
          responseHeaderHook:(void (^)(NSDictionary *initialMetadata,
                                       GRPCInterceptorManager *manager))responseHeaderHook
            responseDataHook:(void (^)(id data, GRPCInterceptorManager *manager))responseDataHook
           responseCloseHook:(void (^)(NSDictionary *trailingMetadata, NSError *error,
                                       GRPCInterceptorManager *manager))responseCloseHook
            didWriteDataHook:(void (^)(GRPCInterceptorManager *manager))didWriteDataHook;

- (GRPCInterceptor *)createInterceptorWithManager:(GRPCInterceptorManager *)interceptorManager;

@end

@interface HookIntercetpor : GRPCInterceptor

- (instancetype)
initWithInterceptorManager:(GRPCInterceptorManager *)interceptorManager
      requestDispatchQueue:(dispatch_queue_t)requestDispatchQueue
     responseDispatchQueue:(dispatch_queue_t)responseDispatchQueue
                 startHook:(void (^)(GRPCRequestOptions *requestOptions,
                                     GRPCCallOptions *callOptions,
                                     GRPCInterceptorManager *manager))startHook
             writeDataHook:(void (^)(id data, GRPCInterceptorManager *manager))writeDataHook
                finishHook:(void (^)(GRPCInterceptorManager *manager))finishHook
   receiveNextMessagesHook:(void (^)(NSUInteger numberOfMessages,
                                     GRPCInterceptorManager *manager))receiveNextMessagesHook
        responseHeaderHook:(void (^)(NSDictionary *initialMetadata,
                                     GRPCInterceptorManager *manager))responseHeaderHook
          responseDataHook:(void (^)(id data, GRPCInterceptorManager *manager))responseDataHook
         responseCloseHook:(void (^)(NSDictionary *trailingMetadata, NSError *error,
                                     GRPCInterceptorManager *manager))responseCloseHook
          didWriteDataHook:(void (^)(GRPCInterceptorManager *manager))didWriteDataHook;

@end

@implementation HookInterceptorFactory {
  void (^_startHook)(GRPCRequestOptions *requestOptions, GRPCCallOptions *callOptions,
                     GRPCInterceptorManager *manager);
  void (^_writeDataHook)(id data, GRPCInterceptorManager *manager);
  void (^_finishHook)(GRPCInterceptorManager *manager);
  void (^_receiveNextMessagesHook)(NSUInteger numberOfMessages, GRPCInterceptorManager *manager);
  void (^_responseHeaderHook)(NSDictionary *initialMetadata, GRPCInterceptorManager *manager);
  void (^_responseDataHook)(id data, GRPCInterceptorManager *manager);
  void (^_responseCloseHook)(NSDictionary *trailingMetadata, NSError *error,
                             GRPCInterceptorManager *manager);
  void (^_didWriteDataHook)(GRPCInterceptorManager *manager);
  dispatch_queue_t _requestDispatchQueue;
  dispatch_queue_t _responseDispatchQueue;
}

- (instancetype)
initWithRequestDispatchQueue:(dispatch_queue_t)requestDispatchQueue
       responseDispatchQueue:(dispatch_queue_t)responseDispatchQueue
                   startHook:(void (^)(GRPCRequestOptions *requestOptions,
                                       GRPCCallOptions *callOptions,
                                       GRPCInterceptorManager *manager))startHook
               writeDataHook:(void (^)(id data, GRPCInterceptorManager *manager))writeDataHook
                  finishHook:(void (^)(GRPCInterceptorManager *manager))finishHook
     receiveNextMessagesHook:(void (^)(NSUInteger numberOfMessages,
                                       GRPCInterceptorManager *manager))receiveNextMessagesHook
          responseHeaderHook:(void (^)(NSDictionary *initialMetadata,
                                       GRPCInterceptorManager *manager))responseHeaderHook
            responseDataHook:(void (^)(id data, GRPCInterceptorManager *manager))responseDataHook
           responseCloseHook:(void (^)(NSDictionary *trailingMetadata, NSError *error,
                                       GRPCInterceptorManager *manager))responseCloseHook
            didWriteDataHook:(void (^)(GRPCInterceptorManager *manager))didWriteDataHook {
  if ((self = [super init])) {
    _requestDispatchQueue = requestDispatchQueue;
    _responseDispatchQueue = responseDispatchQueue;
    _startHook = startHook;
    _writeDataHook = writeDataHook;
    _finishHook = finishHook;
    _receiveNextMessagesHook = receiveNextMessagesHook;
    _responseHeaderHook = responseHeaderHook;
    _responseDataHook = responseDataHook;
    _responseCloseHook = responseCloseHook;
    _didWriteDataHook = didWriteDataHook;
  }
  return self;
}

- (GRPCInterceptor *)createInterceptorWithManager:(GRPCInterceptorManager *)interceptorManager {
  return [[HookIntercetpor alloc] initWithInterceptorManager:interceptorManager
                                        requestDispatchQueue:_requestDispatchQueue
                                       responseDispatchQueue:_responseDispatchQueue
                                                   startHook:_startHook
                                               writeDataHook:_writeDataHook
                                                  finishHook:_finishHook
                                     receiveNextMessagesHook:_receiveNextMessagesHook
                                          responseHeaderHook:_responseHeaderHook
                                            responseDataHook:_responseDataHook
                                           responseCloseHook:_responseCloseHook
                                            didWriteDataHook:_didWriteDataHook];
}

@end

@implementation HookIntercetpor {
  void (^_startHook)(GRPCRequestOptions *requestOptions, GRPCCallOptions *callOptions,
                     GRPCInterceptorManager *manager);
  void (^_writeDataHook)(id data, GRPCInterceptorManager *manager);
  void (^_finishHook)(GRPCInterceptorManager *manager);
  void (^_receiveNextMessagesHook)(NSUInteger numberOfMessages, GRPCInterceptorManager *manager);
  void (^_responseHeaderHook)(NSDictionary *initialMetadata, GRPCInterceptorManager *manager);
  void (^_responseDataHook)(id data, GRPCInterceptorManager *manager);
  void (^_responseCloseHook)(NSDictionary *trailingMetadata, NSError *error,
                             GRPCInterceptorManager *manager);
  void (^_didWriteDataHook)(GRPCInterceptorManager *manager);
  GRPCInterceptorManager *_manager;
  dispatch_queue_t _requestDispatchQueue;
  dispatch_queue_t _responseDispatchQueue;
}

- (dispatch_queue_t)requestDispatchQueue {
  return _requestDispatchQueue;
}

- (dispatch_queue_t)dispatchQueue {
  return _responseDispatchQueue;
}

- (instancetype)
initWithInterceptorManager:(GRPCInterceptorManager *)interceptorManager
      requestDispatchQueue:(dispatch_queue_t)requestDispatchQueue
     responseDispatchQueue:(dispatch_queue_t)responseDispatchQueue
                 startHook:(void (^)(GRPCRequestOptions *requestOptions,
                                     GRPCCallOptions *callOptions,
                                     GRPCInterceptorManager *manager))startHook
             writeDataHook:(void (^)(id data, GRPCInterceptorManager *manager))writeDataHook
                finishHook:(void (^)(GRPCInterceptorManager *manager))finishHook
   receiveNextMessagesHook:(void (^)(NSUInteger numberOfMessages,
                                     GRPCInterceptorManager *manager))receiveNextMessagesHook
        responseHeaderHook:(void (^)(NSDictionary *initialMetadata,
                                     GRPCInterceptorManager *manager))responseHeaderHook
          responseDataHook:(void (^)(id data, GRPCInterceptorManager *manager))responseDataHook
         responseCloseHook:(void (^)(NSDictionary *trailingMetadata, NSError *error,
                                     GRPCInterceptorManager *manager))responseCloseHook
          didWriteDataHook:(void (^)(GRPCInterceptorManager *manager))didWriteDataHook {
  if ((self = [super initWithInterceptorManager:interceptorManager
                           requestDispatchQueue:requestDispatchQueue
                          responseDispatchQueue:responseDispatchQueue])) {
    _startHook = startHook;
    _writeDataHook = writeDataHook;
    _finishHook = finishHook;
    _receiveNextMessagesHook = receiveNextMessagesHook;
    _responseHeaderHook = responseHeaderHook;
    _responseDataHook = responseDataHook;
    _responseCloseHook = responseCloseHook;
    _didWriteDataHook = didWriteDataHook;
    _requestDispatchQueue = requestDispatchQueue;
    _responseDispatchQueue = responseDispatchQueue;
    _manager = interceptorManager;
  }
  return self;
}

- (void)startWithRequestOptions:(GRPCRequestOptions *)requestOptions
                    callOptions:(GRPCCallOptions *)callOptions {
  if (_startHook) {
    _startHook(requestOptions, callOptions, _manager);
  }
}

- (void)writeData:(id)data {
  if (_writeDataHook) {
    _writeDataHook(data, _manager);
  }
}

- (void)finish {
  if (_finishHook) {
    _finishHook(_manager);
  }
}

- (void)receiveNextMessages:(NSUInteger)numberOfMessages {
  if (_receiveNextMessagesHook) {
    _receiveNextMessagesHook(numberOfMessages, _manager);
  }
}

- (void)didReceiveInitialMetadata:(NSDictionary *)initialMetadata {
  if (_responseHeaderHook) {
    _responseHeaderHook(initialMetadata, _manager);
  }
}

- (void)didReceiveData:(id)data {
  if (_responseDataHook) {
    _responseDataHook(data, _manager);
  }
}

- (void)didCloseWithTrailingMetadata:(NSDictionary *)trailingMetadata error:(NSError *)error {
  if (_responseCloseHook) {
    _responseCloseHook(trailingMetadata, error, _manager);
  }
}

- (void)didWriteData {
  if (_didWriteDataHook) {
    _didWriteDataHook(_manager);
  }
}

@end

#pragma mark Tests

@implementation InteropTests {
  RMTTestService *_service;
}

+ (NSString *)host {
  return nil;
}

// This number indicates how many bytes of overhead does Protocol Buffers encoding add onto the
// message. The number varies as different message.proto is used on different servers. The actual
// number for each interop server is overridden in corresponding derived test classes.
- (int32_t)encodingOverhead {
  return 0;
}

+ (GRPCTransportType)transportType {
  return GRPCTransportTypeChttp2BoringSSL;
}

+ (NSString *)PEMRootCertificates {
  return nil;
}

+ (NSString *)hostNameOverride {
  return nil;
}

+ (BOOL)useCronet {
  return NO;
}

+ (BOOL)canRunCompressionTest {
  return YES;
}

+ (void)setUp {
#ifdef GRPC_COMPILE_WITH_CRONET
  configureCronet();
  if ([self useCronet]) {
    [GRPCCall useCronetWithEngine:[Cronet getGlobalEngine]];
  }
#endif
#ifdef GRPC_CFSTREAM
  setenv(kCFStreamVarName, "1", 1);
#endif
}

- (void)setUp {
  self.continueAfterFailure = NO;

  [GRPCCall resetHostSettings];

  _service = [[self class] host] ? [RMTTestService serviceWithHost:[[self class] host]] : nil;
}

- (void)testEmptyUnaryRPC {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"EmptyUnary"];

  GPBEmpty *request = [GPBEmpty message];

  [_service emptyCallWithRequest:request
                         handler:^(GPBEmpty *response, NSError *error) {
                           XCTAssertNil(error, @"Finished with unexpected error: %@", error);

                           id expectedResponse = [GPBEmpty message];
                           XCTAssertEqualObjects(response, expectedResponse);

                           [expectation fulfill];
                         }];

  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testEmptyUnaryRPCWithV2API {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectReceive =
      [self expectationWithDescription:@"EmptyUnaryWithV2API received message"];
  __weak XCTestExpectation *expectComplete =
      [self expectationWithDescription:@"EmptyUnaryWithV2API completed"];

  GPBEmpty *request = [GPBEmpty message];
  GRPCMutableCallOptions *options = [[GRPCMutableCallOptions alloc] init];
  options.transportType = [[self class] transportType];
  options.PEMRootCertificates = [[self class] PEMRootCertificates];
  options.hostNameOverride = [[self class] hostNameOverride];

  GRPCUnaryProtoCall *call = [_service
      emptyCallWithMessage:request
           responseHandler:[[InteropTestsBlockCallbacks alloc] initWithInitialMetadataCallback:nil
                               messageCallback:^(id message) {
                                 if (message) {
                                   id expectedResponse = [GPBEmpty message];
                                   XCTAssertEqualObjects(message, expectedResponse);
                                   [expectReceive fulfill];
                                 }
                               }
                               closeCallback:^(NSDictionary *trailingMetadata, NSError *error) {
                                 XCTAssertNil(error, @"Unexpected error: %@", error);
                                 [expectComplete fulfill];
                               }]
               callOptions:options];
  [call start];
  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

// Test that responses can be dispatched even if we do not run main run-loop
- (void)testAsyncDispatchWithV2API {
  XCTAssertNotNil([[self class] host]);

  GPBEmpty *request = [GPBEmpty message];
  GRPCMutableCallOptions *options = [[GRPCMutableCallOptions alloc] init];
  options.transportType = [[self class] transportType];
  options.PEMRootCertificates = [[self class] PEMRootCertificates];
  options.hostNameOverride = [[self class] hostNameOverride];

  __block BOOL messageReceived = NO;
  __block BOOL done = NO;
  __block BOOL initialMetadataReceived = YES;
  NSCondition *cond = [[NSCondition alloc] init];
  GRPCUnaryProtoCall *call = [_service
      emptyCallWithMessage:request
           responseHandler:[[InteropTestsBlockCallbacks alloc]
                               initWithInitialMetadataCallback:^(NSDictionary *initialMetadata) {
                                 [cond lock];
                                 initialMetadataReceived = YES;
                                 [cond unlock];
                               }
                               messageCallback:^(id message) {
                                 if (message) {
                                   id expectedResponse = [GPBEmpty message];
                                   XCTAssertEqualObjects(message, expectedResponse);
                                   [cond lock];
                                   messageReceived = YES;
                                   [cond unlock];
                                 }
                               }
                               closeCallback:^(NSDictionary *trailingMetadata, NSError *error) {
                                 XCTAssertNil(error, @"Unexpected error: %@", error);
                                 [cond lock];
                                 done = YES;
                                 [cond signal];
                                 [cond unlock];
                               }]
               callOptions:options];

  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:TEST_TIMEOUT];
  [call start];

  [cond lock];
  while (!done && [deadline timeIntervalSinceNow] > 0) {
    [cond waitUntilDate:deadline];
  }
  XCTAssertTrue(initialMetadataReceived);
  XCTAssertTrue(messageReceived);
  XCTAssertTrue(done);
  [cond unlock];
}

- (void)testLargeUnaryRPC {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"LargeUnary"];

  RMTSimpleRequest *request = [RMTSimpleRequest message];
  request.responseType = RMTPayloadType_Compressable;
  request.responseSize = 314159;
  request.payload.body = [NSMutableData dataWithLength:271828];

  [_service unaryCallWithRequest:request
                         handler:^(RMTSimpleResponse *response, NSError *error) {
                           XCTAssertNil(error, @"Finished with unexpected error: %@", error);

                           RMTSimpleResponse *expectedResponse = [RMTSimpleResponse message];
                           expectedResponse.payload.type = RMTPayloadType_Compressable;
                           expectedResponse.payload.body = [NSMutableData dataWithLength:314159];
                           XCTAssertEqualObjects(response, expectedResponse);

                           [expectation fulfill];
                         }];

  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testLargeUnaryRPCWithV2API {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectReceive =
      [self expectationWithDescription:@"LargeUnaryWithV2API received message"];
  __weak XCTestExpectation *expectComplete =
      [self expectationWithDescription:@"LargeUnaryWithV2API received complete"];

  RMTSimpleRequest *request = [RMTSimpleRequest message];
  request.responseType = RMTPayloadType_Compressable;
  request.responseSize = 314159;
  request.payload.body = [NSMutableData dataWithLength:271828];

  GRPCMutableCallOptions *options = [[GRPCMutableCallOptions alloc] init];
  options.transportType = [[self class] transportType];
  options.PEMRootCertificates = [[self class] PEMRootCertificates];
  options.hostNameOverride = [[self class] hostNameOverride];

  GRPCUnaryProtoCall *call = [_service
      unaryCallWithMessage:request
           responseHandler:[[InteropTestsBlockCallbacks alloc] initWithInitialMetadataCallback:nil
                               messageCallback:^(id message) {
                                 XCTAssertNotNil(message);
                                 if (message) {
                                   RMTSimpleResponse *expectedResponse =
                                       [RMTSimpleResponse message];
                                   expectedResponse.payload.type = RMTPayloadType_Compressable;
                                   expectedResponse.payload.body =
                                       [NSMutableData dataWithLength:314159];
                                   XCTAssertEqualObjects(message, expectedResponse);

                                   [expectReceive fulfill];
                                 }
                               }
                               closeCallback:^(NSDictionary *trailingMetadata, NSError *error) {
                                 XCTAssertNil(error, @"Unexpected error: %@", error);
                                 [expectComplete fulfill];
                               }]
               callOptions:options];
  [call start];
  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testConcurrentRPCsWithErrorsWithV2API {
  NSMutableArray *completeExpectations = [NSMutableArray array];
  NSMutableArray *calls = [NSMutableArray array];
  int num_rpcs = 10;
  for (int i = 0; i < num_rpcs; ++i) {
    [completeExpectations
        addObject:[self expectationWithDescription:
                            [NSString stringWithFormat:@"Received trailer for RPC %d", i]]];

    RMTSimpleRequest *request = [RMTSimpleRequest message];
    request.responseType = RMTPayloadType_Compressable;
    request.responseSize = 314159;
    request.payload.body = [NSMutableData dataWithLength:271828];
    if (i % 3 == 0) {
      request.responseStatus.code = GRPC_STATUS_UNAVAILABLE;
    } else if (i % 7 == 0) {
      request.responseStatus.code = GRPC_STATUS_CANCELLED;
    }
    GRPCMutableCallOptions *options = [[GRPCMutableCallOptions alloc] init];
    options.transportType = [[self class] transportType];
    options.PEMRootCertificates = [[self class] PEMRootCertificates];
    options.hostNameOverride = [[self class] hostNameOverride];

    GRPCUnaryProtoCall *call = [_service
        unaryCallWithMessage:request
             responseHandler:[[InteropTestsBlockCallbacks alloc] initWithInitialMetadataCallback:nil
                                 messageCallback:^(id message) {
                                   if (message) {
                                     RMTSimpleResponse *expectedResponse =
                                         [RMTSimpleResponse message];
                                     expectedResponse.payload.type = RMTPayloadType_Compressable;
                                     expectedResponse.payload.body =
                                         [NSMutableData dataWithLength:314159];
                                     XCTAssertEqualObjects(message, expectedResponse);
                                   }
                                 }
                                 closeCallback:^(NSDictionary *trailingMetadata, NSError *error) {
                                   [completeExpectations[i] fulfill];
                                 }]
                 callOptions:options];
    [calls addObject:call];
  }

  for (int i = 0; i < num_rpcs; ++i) {
    GRPCUnaryProtoCall *call = calls[i];
    [call start];
  }
  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testConcurrentRPCsWithErrors {
  NSMutableArray *completeExpectations = [NSMutableArray array];
  int num_rpcs = 10;
  for (int i = 0; i < num_rpcs; ++i) {
    [completeExpectations
        addObject:[self expectationWithDescription:
                            [NSString stringWithFormat:@"Received trailer for RPC %d", i]]];

    RMTSimpleRequest *request = [RMTSimpleRequest message];
    request.responseType = RMTPayloadType_Compressable;
    request.responseSize = 314159;
    request.payload.body = [NSMutableData dataWithLength:271828];
    if (i % 3 == 0) {
      request.responseStatus.code = GRPC_STATUS_UNAVAILABLE;
    } else if (i % 7 == 0) {
      request.responseStatus.code = GRPC_STATUS_CANCELLED;
    }

    [_service unaryCallWithRequest:request
                           handler:^(RMTSimpleResponse *response, NSError *error) {
                             if (error == nil) {
                               RMTSimpleResponse *expectedResponse = [RMTSimpleResponse message];
                               expectedResponse.payload.type = RMTPayloadType_Compressable;
                               expectedResponse.payload.body =
                                   [NSMutableData dataWithLength:314159];
                               XCTAssertEqualObjects(response, expectedResponse);
                             }
                             [completeExpectations[i] fulfill];
                           }];
  }

  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testPacketCoalescing {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"LargeUnary"];

  RMTSimpleRequest *request = [RMTSimpleRequest message];
  request.responseType = RMTPayloadType_Compressable;
  request.responseSize = 10;
  request.payload.body = [NSMutableData dataWithLength:10];

  [GRPCCall enableOpBatchLog:YES];
  [_service unaryCallWithRequest:request
                         handler:^(RMTSimpleResponse *response, NSError *error) {
                           XCTAssertNil(error, @"Finished with unexpected error: %@", error);

                           RMTSimpleResponse *expectedResponse = [RMTSimpleResponse message];
                           expectedResponse.payload.type = RMTPayloadType_Compressable;
                           expectedResponse.payload.body = [NSMutableData dataWithLength:10];
                           XCTAssertEqualObjects(response, expectedResponse);

                           // The test is a success if there is a batch of exactly 3 ops
                           // (SEND_INITIAL_METADATA, SEND_MESSAGE, SEND_CLOSE_FROM_CLIENT). Without
                           // packet coalescing each batch of ops contains only one op.
                           NSArray *opBatches = [GRPCCall obtainAndCleanOpBatchLog];
                           const NSInteger kExpectedOpBatchSize = 3;
                           for (NSObject *o in opBatches) {
                             if ([o isKindOfClass:[NSArray class]]) {
                               NSArray *batch = (NSArray *)o;
                               if ([batch count] == kExpectedOpBatchSize) {
                                 [expectation fulfill];
                                 break;
                               }
                             }
                           }
                         }];

  [self waitForExpectationsWithTimeout:16 handler:nil];
  [GRPCCall enableOpBatchLog:NO];
}

- (void)test4MBResponsesAreAccepted {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"MaxResponseSize"];

  RMTSimpleRequest *request = [RMTSimpleRequest message];
  const int32_t kPayloadSize = 4 * 1024 * 1024 - self.encodingOverhead;  // 4MB - encoding overhead
  request.responseSize = kPayloadSize;

  [_service unaryCallWithRequest:request
                         handler:^(RMTSimpleResponse *response, NSError *error) {
                           XCTAssertNil(error, @"Finished with unexpected error: %@", error);
                           XCTAssertEqual(response.payload.body.length, kPayloadSize);
                           [expectation fulfill];
                         }];

  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testResponsesOverMaxSizeFailWithActionableMessage {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"ResponseOverMaxSize"];

  RMTSimpleRequest *request = [RMTSimpleRequest message];
  const int32_t kPayloadSize = 4 * 1024 * 1024 - self.encodingOverhead + 1;  // 1B over max size
  request.responseSize = kPayloadSize;

  [_service unaryCallWithRequest:request
                         handler:^(RMTSimpleResponse *response, NSError *error) {
                           // TODO(jcanizales): Catch the error and rethrow it with an actionable
                           // message:
                           // - Use +[GRPCCall setResponseSizeLimit:forHost:] to set a higher limit.
                           // - If you're developing the server, consider using response streaming,
                           // or let clients filter
                           //   responses by setting a google.protobuf.FieldMask in the request:
                           //   https://github.com/google/protobuf/blob/master/src/google/protobuf/field_mask.proto
                           XCTAssertEqualObjects(
                               error.localizedDescription,
                               @"Received message larger than max (4194305 vs. 4194304)");
                           [expectation fulfill];
                         }];

  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testResponsesOver4MBAreAcceptedIfOptedIn {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation =
      [self expectationWithDescription:@"HigherResponseSizeLimit"];
  __block NSError *callError = nil;

  RMTSimpleRequest *request = [RMTSimpleRequest message];
  const size_t kPayloadSize = 5 * 1024 * 1024;  // 5MB
  request.responseSize = kPayloadSize;

  [GRPCCall setResponseSizeLimit:6 * 1024 * 1024 forHost:[[self class] host]];
  [_service unaryCallWithRequest:request
                         handler:^(RMTSimpleResponse *response, NSError *error) {
                           callError = error;
                           [expectation fulfill];
                         }];

  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
  XCTAssertNil(callError, @"Finished with unexpected error: %@", callError);
}

- (void)testClientStreamingRPC {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"ClientStreaming"];

  RMTStreamingInputCallRequest *request1 = [RMTStreamingInputCallRequest message];
  request1.payload.body = [NSMutableData dataWithLength:27182];

  RMTStreamingInputCallRequest *request2 = [RMTStreamingInputCallRequest message];
  request2.payload.body = [NSMutableData dataWithLength:8];

  RMTStreamingInputCallRequest *request3 = [RMTStreamingInputCallRequest message];
  request3.payload.body = [NSMutableData dataWithLength:1828];

  RMTStreamingInputCallRequest *request4 = [RMTStreamingInputCallRequest message];
  request4.payload.body = [NSMutableData dataWithLength:45904];

  GRXWriter *writer = [GRXWriter writerWithContainer:@[ request1, request2, request3, request4 ]];

  [_service streamingInputCallWithRequestsWriter:writer
                                         handler:^(RMTStreamingInputCallResponse *response,
                                                   NSError *error) {
                                           XCTAssertNil(
                                               error, @"Finished with unexpected error: %@", error);

                                           RMTStreamingInputCallResponse *expectedResponse =
                                               [RMTStreamingInputCallResponse message];
                                           expectedResponse.aggregatedPayloadSize = 74922;
                                           XCTAssertEqualObjects(response, expectedResponse);

                                           [expectation fulfill];
                                         }];

  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testServerStreamingRPC {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"ServerStreaming"];

  NSArray *expectedSizes = @[ @31415, @9, @2653, @58979 ];

  RMTStreamingOutputCallRequest *request = [RMTStreamingOutputCallRequest message];
  for (NSNumber *size in expectedSizes) {
    RMTResponseParameters *parameters = [RMTResponseParameters message];
    parameters.size = [size intValue];
    [request.responseParametersArray addObject:parameters];
  }

  __block int index = 0;
  [_service
      streamingOutputCallWithRequest:request
                        eventHandler:^(BOOL done, RMTStreamingOutputCallResponse *response,
                                       NSError *error) {
                          XCTAssertNil(error, @"Finished with unexpected error: %@", error);
                          XCTAssertTrue(done || response,
                                        @"Event handler called without an event.");

                          if (response) {
                            XCTAssertLessThan(index, 4, @"More than 4 responses received.");
                            id expected = [RMTStreamingOutputCallResponse
                                messageWithPayloadSize:expectedSizes[index]];
                            XCTAssertEqualObjects(response, expected);
                            index += 1;
                          }

                          if (done) {
                            XCTAssertEqual(index, 4, @"Received %i responses instead of 4.", index);
                            [expectation fulfill];
                          }
                        }];

  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testPingPongRPC {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"PingPong"];

  NSArray *requests = @[ @27182, @8, @1828, @45904 ];
  NSArray *responses = @[ @31415, @9, @2653, @58979 ];

  GRXBufferedPipe *requestsBuffer = [[GRXBufferedPipe alloc] init];

  __block int index = 0;

  id request = [RMTStreamingOutputCallRequest messageWithPayloadSize:requests[index]
                                               requestedResponseSize:responses[index]];
  [requestsBuffer writeValue:request];

  [_service fullDuplexCallWithRequestsWriter:requestsBuffer
                                eventHandler:^(BOOL done, RMTStreamingOutputCallResponse *response,
                                               NSError *error) {
                                  XCTAssertNil(error, @"Finished with unexpected error: %@", error);
                                  XCTAssertTrue(done || response,
                                                @"Event handler called without an event.");

                                  if (response) {
                                    XCTAssertLessThan(index, 4, @"More than 4 responses received.");
                                    id expected = [RMTStreamingOutputCallResponse
                                        messageWithPayloadSize:responses[index]];
                                    XCTAssertEqualObjects(response, expected);
                                    index += 1;
                                    if (index < 4) {
                                      id request = [RMTStreamingOutputCallRequest
                                          messageWithPayloadSize:requests[index]
                                           requestedResponseSize:responses[index]];
                                      [requestsBuffer writeValue:request];
                                    } else {
                                      [requestsBuffer writesFinishedWithError:nil];
                                    }
                                  }

                                  if (done) {
                                    XCTAssertEqual(index, 4, @"Received %i responses instead of 4.",
                                                   index);
                                    [expectation fulfill];
                                  }
                                }];
  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testPingPongRPCWithV2API {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"PingPongWithV2API"];

  NSArray *requests = @[ @27182, @8, @1828, @45904 ];
  NSArray *responses = @[ @31415, @9, @2653, @58979 ];

  __block int index = 0;

  id request = [RMTStreamingOutputCallRequest messageWithPayloadSize:requests[index]
                                               requestedResponseSize:responses[index]];
  GRPCMutableCallOptions *options = [[GRPCMutableCallOptions alloc] init];
  options.transportType = [[self class] transportType];
  options.PEMRootCertificates = [[self class] PEMRootCertificates];
  options.hostNameOverride = [[self class] hostNameOverride];

  __block GRPCStreamingProtoCall *call = [_service
      fullDuplexCallWithResponseHandler:[[InteropTestsBlockCallbacks alloc]
                                            initWithInitialMetadataCallback:nil
                                            messageCallback:^(id message) {
                                              XCTAssertLessThan(index, 4,
                                                                @"More than 4 responses received.");
                                              id expected = [RMTStreamingOutputCallResponse
                                                  messageWithPayloadSize:responses[index]];
                                              XCTAssertEqualObjects(message, expected);
                                              index += 1;
                                              if (index < 4) {
                                                id request = [RMTStreamingOutputCallRequest
                                                    messageWithPayloadSize:requests[index]
                                                     requestedResponseSize:responses[index]];
                                                [call writeMessage:request];
                                              } else {
                                                [call finish];
                                              }
                                            }
                                            closeCallback:^(NSDictionary *trailingMetadata,
                                                            NSError *error) {
                                              XCTAssertNil(error,
                                                           @"Finished with unexpected error: %@",
                                                           error);
                                              XCTAssertEqual(index, 4,
                                                             @"Received %i responses instead of 4.",
                                                             index);
                                              [expectation fulfill];
                                            }]
                            callOptions:options];
  [call start];
  [call writeMessage:request];

  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testPingPongRPCWithFlowControl {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"PingPongWithV2API"];

  NSArray *requests = @[ @27182, @8, @1828, @45904 ];
  NSArray *responses = @[ @31415, @9, @2653, @58979 ];

  __block int index = 0;

  id request = [RMTStreamingOutputCallRequest messageWithPayloadSize:requests[index]
                                               requestedResponseSize:responses[index]];
  GRPCMutableCallOptions *options = [[GRPCMutableCallOptions alloc] init];
  options.transportType = [[self class] transportType];
  options.PEMRootCertificates = [[self class] PEMRootCertificates];
  options.hostNameOverride = [[self class] hostNameOverride];
  options.flowControlEnabled = YES;
  __block BOOL canWriteData = NO;

  __block GRPCStreamingProtoCall *call = [_service
      fullDuplexCallWithResponseHandler:[[InteropTestsBlockCallbacks alloc]
                                            initWithInitialMetadataCallback:nil
                                            messageCallback:^(id message) {
                                              XCTAssertLessThan(index, 4,
                                                                @"More than 4 responses received.");
                                              id expected = [RMTStreamingOutputCallResponse
                                                  messageWithPayloadSize:responses[index]];
                                              XCTAssertEqualObjects(message, expected);
                                              index += 1;
                                              if (index < 4) {
                                                id request = [RMTStreamingOutputCallRequest
                                                    messageWithPayloadSize:requests[index]
                                                     requestedResponseSize:responses[index]];
                                                XCTAssertTrue(canWriteData);
                                                canWriteData = NO;
                                                [call writeMessage:request];
                                                [call receiveNextMessage];
                                              } else {
                                                [call finish];
                                              }
                                            }
                                            closeCallback:^(NSDictionary *trailingMetadata,
                                                            NSError *error) {
                                              XCTAssertNil(error,
                                                           @"Finished with unexpected error: %@",
                                                           error);
                                              XCTAssertEqual(index, 4,
                                                             @"Received %i responses instead of 4.",
                                                             index);
                                              [expectation fulfill];
                                            }
                                            writeMessageCallback:^{
                                              canWriteData = YES;
                                            }]
                            callOptions:options];
  [call start];
  [call receiveNextMessage];
  [call writeMessage:request];

  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testEmptyStreamRPC {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"EmptyStream"];
  [_service fullDuplexCallWithRequestsWriter:[GRXWriter emptyWriter]
                                eventHandler:^(BOOL done, RMTStreamingOutputCallResponse *response,
                                               NSError *error) {
                                  XCTAssertNil(error, @"Finished with unexpected error: %@", error);
                                  XCTAssert(done, @"Unexpected response: %@", response);
                                  [expectation fulfill];
                                }];
  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testCancelAfterBeginRPC {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"CancelAfterBegin"];

  // A buffered pipe to which we never write any value acts as a writer that just hangs.
  GRXBufferedPipe *requestsBuffer = [[GRXBufferedPipe alloc] init];

  GRPCProtoCall *call = [_service
      RPCToStreamingInputCallWithRequestsWriter:requestsBuffer
                                        handler:^(RMTStreamingInputCallResponse *response,
                                                  NSError *error) {
                                          XCTAssertEqual(error.code, GRPC_STATUS_CANCELLED);
                                          [expectation fulfill];
                                        }];
  XCTAssertEqual(call.state, GRXWriterStateNotStarted);

  [call start];
  XCTAssertEqual(call.state, GRXWriterStateStarted);

  [call cancel];
  XCTAssertEqual(call.state, GRXWriterStateFinished);

  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testCancelAfterBeginRPCWithV2API {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation =
      [self expectationWithDescription:@"CancelAfterBeginWithV2API"];

  // A buffered pipe to which we never write any value acts as a writer that just hangs.
  __block GRPCStreamingProtoCall *call = [_service
      streamingInputCallWithResponseHandler:[[InteropTestsBlockCallbacks alloc]
                                                initWithInitialMetadataCallback:nil
                                                messageCallback:^(id message) {
                                                  XCTFail(@"Not expected to receive message");
                                                }
                                                closeCallback:^(NSDictionary *trailingMetadata,
                                                                NSError *error) {
                                                  XCTAssertEqual(error.code, GRPC_STATUS_CANCELLED);
                                                  [expectation fulfill];
                                                }]
                                callOptions:nil];
  [call start];
  [call cancel];

  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testInitialMetadataWithV2API {
  __weak XCTestExpectation *initialMetadataReceived =
      [self expectationWithDescription:@"Received initial metadata."];
  __weak XCTestExpectation *closeReceived = [self expectationWithDescription:@"RPC completed."];

  __block NSDictionary *init_md =
      [NSDictionary dictionaryWithObjectsAndKeys:@"FOOBAR", @"x-grpc-test-echo-initial", nil];
  GRPCMutableCallOptions *options = [[GRPCMutableCallOptions alloc] init];
  options.initialMetadata = init_md;
  options.transportType = self.class.transportType;
  options.PEMRootCertificates = self.class.PEMRootCertificates;
  options.hostNameOverride = [[self class] hostNameOverride];
  RMTSimpleRequest *request = [RMTSimpleRequest message];
  __block bool init_md_received = NO;
  GRPCUnaryProtoCall *call = [_service
      unaryCallWithMessage:request
           responseHandler:[[InteropTestsBlockCallbacks alloc]
                               initWithInitialMetadataCallback:^(NSDictionary *initialMetadata) {
                                 XCTAssertEqualObjects(initialMetadata[@"x-grpc-test-echo-initial"],
                                                       init_md[@"x-grpc-test-echo-initial"]);
                                 init_md_received = YES;
                                 [initialMetadataReceived fulfill];
                               }
                               messageCallback:nil
                               closeCallback:^(NSDictionary *trailingMetadata, NSError *error) {
                                 XCTAssertNil(error, @"Unexpected error: %@", error);
                                 [closeReceived fulfill];
                               }]
               callOptions:options];

  [call start];
  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testTrailingMetadataWithV2API {
  // This test needs to be disabled for remote test because interop server grpc-test
  // does not send trailing binary metadata.
  if (isRemoteInteropTest([[self class] host])) {
    return;
  }

  __weak XCTestExpectation *expectation =
      [self expectationWithDescription:@"Received trailing metadata."];
  const unsigned char raw_bytes[] = {0x1, 0x2, 0x3, 0x4};
  NSData *trailer_data = [NSData dataWithBytes:raw_bytes length:sizeof(raw_bytes)];
  __block NSDictionary *trailer = [NSDictionary
      dictionaryWithObjectsAndKeys:trailer_data, @"x-grpc-test-echo-trailing-bin", nil];
  GRPCMutableCallOptions *options = [[GRPCMutableCallOptions alloc] init];
  options.initialMetadata = trailer;
  options.transportType = self.class.transportType;
  options.PEMRootCertificates = self.class.PEMRootCertificates;
  options.hostNameOverride = [[self class] hostNameOverride];
  RMTSimpleRequest *request = [RMTSimpleRequest message];
  GRPCUnaryProtoCall *call = [_service
      unaryCallWithMessage:request
           responseHandler:
               [[InteropTestsBlockCallbacks alloc]
                   initWithInitialMetadataCallback:nil
                                   messageCallback:nil
                                     closeCallback:^(NSDictionary *trailingMetadata,
                                                     NSError *error) {
                                       XCTAssertNil(error, @"Unexpected error: %@", error);
                                       XCTAssertEqualObjects(
                                           trailingMetadata[@"x-grpc-test-echo-trailing-bin"],
                                           trailer[@"x-grpc-test-echo-trailing-bin"]);
                                       [expectation fulfill];
                                     }]
               callOptions:options];
  [call start];
  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testCancelAfterFirstResponseRPC {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation =
      [self expectationWithDescription:@"CancelAfterFirstResponse"];

  // A buffered pipe to which we write a single value but never close
  GRXBufferedPipe *requestsBuffer = [[GRXBufferedPipe alloc] init];

  __block BOOL receivedResponse = NO;

  id request =
      [RMTStreamingOutputCallRequest messageWithPayloadSize:@21782 requestedResponseSize:@31415];

  [requestsBuffer writeValue:request];

  __block GRPCProtoCall *call = [_service
      RPCToFullDuplexCallWithRequestsWriter:requestsBuffer
                               eventHandler:^(BOOL done, RMTStreamingOutputCallResponse *response,
                                              NSError *error) {
                                 if (receivedResponse) {
                                   XCTAssert(done, @"Unexpected extra response %@", response);
                                   XCTAssertEqual(error.code, GRPC_STATUS_CANCELLED);
                                   [expectation fulfill];
                                 } else {
                                   XCTAssertNil(error, @"Finished with unexpected error: %@",
                                                error);
                                   XCTAssertFalse(done, @"Finished without response");
                                   XCTAssertNotNil(response);
                                   receivedResponse = YES;
                                   [call cancel];
                                 }
                               }];
  [call start];
  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testCancelAfterFirstResponseRPCWithV2API {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *completionExpectation =
      [self expectationWithDescription:@"Call completed."];
  __weak XCTestExpectation *responseExpectation =
      [self expectationWithDescription:@"Received response."];

  __block BOOL receivedResponse = NO;

  GRPCMutableCallOptions *options = [[GRPCMutableCallOptions alloc] init];
  options.transportType = self.class.transportType;
  options.PEMRootCertificates = self.class.PEMRootCertificates;
  options.hostNameOverride = [[self class] hostNameOverride];

  id request =
      [RMTStreamingOutputCallRequest messageWithPayloadSize:@21782 requestedResponseSize:@31415];

  __block GRPCStreamingProtoCall *call = [_service
      fullDuplexCallWithResponseHandler:[[InteropTestsBlockCallbacks alloc]
                                            initWithInitialMetadataCallback:nil
                                            messageCallback:^(id message) {
                                              XCTAssertFalse(receivedResponse);
                                              receivedResponse = YES;
                                              [call cancel];
                                              [responseExpectation fulfill];
                                            }
                                            closeCallback:^(NSDictionary *trailingMetadata,
                                                            NSError *error) {
                                              XCTAssertEqual(error.code, GRPC_STATUS_CANCELLED);
                                              [completionExpectation fulfill];
                                            }]
                            callOptions:options];
  [call start];
  [call writeMessage:request];
  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testCancelAfterFirstRequestWithV2API {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *completionExpectation =
      [self expectationWithDescription:@"Call completed."];

  GRPCMutableCallOptions *options = [[GRPCMutableCallOptions alloc] init];
  options.transportType = self.class.transportType;
  options.PEMRootCertificates = self.class.PEMRootCertificates;
  options.hostNameOverride = [[self class] hostNameOverride];

  id request =
      [RMTStreamingOutputCallRequest messageWithPayloadSize:@21782 requestedResponseSize:@31415];

  __block GRPCStreamingProtoCall *call = [_service
      fullDuplexCallWithResponseHandler:[[InteropTestsBlockCallbacks alloc]
                                            initWithInitialMetadataCallback:nil
                                            messageCallback:^(id message) {
                                              XCTFail(@"Received unexpected response.");
                                            }
                                            closeCallback:^(NSDictionary *trailingMetadata,
                                                            NSError *error) {
                                              XCTAssertEqual(error.code, GRPC_STATUS_CANCELLED);
                                              [completionExpectation fulfill];
                                            }]
                            callOptions:options];
  [call start];
  [call writeMessage:request];
  [call cancel];
  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testRPCAfterClosingOpenConnections {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation =
      [self expectationWithDescription:@"RPC after closing connection"];

  GPBEmpty *request = [GPBEmpty message];

  [_service
      emptyCallWithRequest:request
                   handler:^(GPBEmpty *response, NSError *error) {
                     XCTAssertNil(error, @"First RPC finished with unexpected error: %@", error);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                     [GRPCCall closeOpenConnections];
#pragma clang diagnostic pop

                     [self->_service
                         emptyCallWithRequest:request
                                      handler:^(GPBEmpty *response, NSError *error) {
                                        XCTAssertNil(
                                            error, @"Second RPC finished with unexpected error: %@",
                                            error);
                                        [expectation fulfill];
                                      }];
                   }];

  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)RPCWithCompressMethod:(GRPCCompressionAlgorithm)compressMethod {
  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"LargeUnary"];

  RMTSimpleRequest *request = [RMTSimpleRequest message];
  request.responseType = RMTPayloadType_Compressable;
  request.responseSize = 314159;
  request.payload.body = [NSMutableData dataWithLength:271828];
  request.expectCompressed.value = YES;
  [GRPCCall setDefaultCompressMethod:compressMethod forhost:[[self class] host]];

  [_service unaryCallWithRequest:request
                         handler:^(RMTSimpleResponse *response, NSError *error) {
                           XCTAssertNil(error, @"Finished with unexpected error: %@", error);

                           RMTSimpleResponse *expectedResponse = [RMTSimpleResponse message];
                           expectedResponse.payload.type = RMTPayloadType_Compressable;
                           expectedResponse.payload.body = [NSMutableData dataWithLength:314159];
                           XCTAssertEqualObjects(response, expectedResponse);

                           [expectation fulfill];
                         }];

  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)RPCWithCompressMethodWithV2API:(GRPCCompressionAlgorithm)compressMethod {
  __weak XCTestExpectation *expectMessage =
      [self expectationWithDescription:@"Reived response from server."];
  __weak XCTestExpectation *expectComplete = [self expectationWithDescription:@"RPC completed."];

  RMTSimpleRequest *request = [RMTSimpleRequest message];
  request.responseType = RMTPayloadType_Compressable;
  request.responseSize = 314159;
  request.payload.body = [NSMutableData dataWithLength:271828];
  request.expectCompressed.value = YES;

  GRPCMutableCallOptions *options = [[GRPCMutableCallOptions alloc] init];
  options.transportType = self.class.transportType;
  options.PEMRootCertificates = self.class.PEMRootCertificates;
  options.hostNameOverride = [[self class] hostNameOverride];
  options.compressionAlgorithm = compressMethod;

  GRPCUnaryProtoCall *call = [_service
      unaryCallWithMessage:request
           responseHandler:[[InteropTestsBlockCallbacks alloc] initWithInitialMetadataCallback:nil
                               messageCallback:^(id message) {
                                 XCTAssertNotNil(message);
                                 if (message) {
                                   RMTSimpleResponse *expectedResponse =
                                       [RMTSimpleResponse message];
                                   expectedResponse.payload.type = RMTPayloadType_Compressable;
                                   expectedResponse.payload.body =
                                       [NSMutableData dataWithLength:314159];
                                   XCTAssertEqualObjects(message, expectedResponse);

                                   [expectMessage fulfill];
                                 }
                               }
                               closeCallback:^(NSDictionary *trailingMetadata, NSError *error) {
                                 XCTAssertNil(error, @"Unexpected error: %@", error);
                                 [expectComplete fulfill];
                               }]
               callOptions:options];
  [call start];

  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testCompressedUnaryRPC {
  if ([[self class] canRunCompressionTest]) {
    for (GRPCCompressionAlgorithm compress = GRPCCompressDeflate;
         compress <= GRPCStreamCompressGzip; ++compress) {
      [self RPCWithCompressMethod:compress];
    }
  }
}

- (void)testCompressedUnaryRPCWithV2API {
  if ([[self class] canRunCompressionTest]) {
    for (GRPCCompressionAlgorithm compress = GRPCCompressDeflate;
         compress <= GRPCStreamCompressGzip; ++compress) {
      [self RPCWithCompressMethodWithV2API:compress];
    }
  }
}

#ifndef GRPC_COMPILE_WITH_CRONET
- (void)testKeepalive {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"Keepalive"];

  [GRPCCall setKeepaliveWithInterval:1500 timeout:0 forHost:[[self class] host]];

  NSArray *requests = @[ @27182, @8 ];
  NSArray *responses = @[ @31415, @9 ];

  GRXBufferedPipe *requestsBuffer = [[GRXBufferedPipe alloc] init];

  __block int index = 0;

  id request = [RMTStreamingOutputCallRequest messageWithPayloadSize:requests[index]
                                               requestedResponseSize:responses[index]];
  [requestsBuffer writeValue:request];

  [_service
      fullDuplexCallWithRequestsWriter:requestsBuffer
                          eventHandler:^(BOOL done, RMTStreamingOutputCallResponse *response,
                                         NSError *error) {
                            if (index == 0) {
                              XCTAssertNil(error, @"Finished with unexpected error: %@", error);
                              XCTAssertTrue(response, @"Event handler called without an event.");
                              XCTAssertFalse(done);
                              index++;
                            } else {
                              // Keepalive should kick after 1s elapsed and fails the call.
                              XCTAssertNotNil(error);
                              XCTAssertEqual(error.code, GRPC_STATUS_UNAVAILABLE);
                              XCTAssertEqualObjects(
                                  error.localizedDescription, @"keepalive watchdog timeout",
                                  @"Unexpected failure that is not keepalive watchdog timeout.");
                              XCTAssertTrue(done);
                              [expectation fulfill];
                            }
                          }];

  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testKeepaliveWithV2API {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"Keepalive"];

  GRPCMutableCallOptions *options = [[GRPCMutableCallOptions alloc] init];
  options.transportType = self.class.transportType;
  options.PEMRootCertificates = self.class.PEMRootCertificates;
  options.hostNameOverride = [[self class] hostNameOverride];
  options.keepaliveInterval = 1.5;
  options.keepaliveTimeout = 0;

  id request =
      [RMTStreamingOutputCallRequest messageWithPayloadSize:@21782 requestedResponseSize:@31415];

  __block GRPCStreamingProtoCall *call = [_service
      fullDuplexCallWithResponseHandler:[[InteropTestsBlockCallbacks alloc]
                                            initWithInitialMetadataCallback:nil
                                                            messageCallback:nil
                                                              closeCallback:^(
                                                                  NSDictionary *trailingMetadata,
                                                                  NSError *error) {
                                                                XCTAssertNotNil(error);
                                                                XCTAssertEqual(
                                                                    error.code,
                                                                    GRPC_STATUS_UNAVAILABLE);
                                                                [expectation fulfill];
                                                              }]
                            callOptions:options];
  [call start];
  [call writeMessage:request];

  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}
#endif

- (void)testDefaultInterceptor {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"PingPongWithV2API"];

  NSArray *requests = @[ @27182, @8, @1828, @45904 ];
  NSArray *responses = @[ @31415, @9, @2653, @58979 ];

  __block int index = 0;

  id request = [RMTStreamingOutputCallRequest messageWithPayloadSize:requests[index]
                                               requestedResponseSize:responses[index]];
  GRPCMutableCallOptions *options = [[GRPCMutableCallOptions alloc] init];
  options.transportType = [[self class] transportType];
  options.PEMRootCertificates = [[self class] PEMRootCertificates];
  options.hostNameOverride = [[self class] hostNameOverride];
  options.interceptorFactories = @[ [[DefaultInterceptorFactory alloc] init] ];

  __block GRPCStreamingProtoCall *call = [_service
      fullDuplexCallWithResponseHandler:[[InteropTestsBlockCallbacks alloc]
                                            initWithInitialMetadataCallback:nil
                                            messageCallback:^(id message) {
                                              XCTAssertLessThan(index, 4,
                                                                @"More than 4 responses received.");
                                              id expected = [RMTStreamingOutputCallResponse
                                                  messageWithPayloadSize:responses[index]];
                                              XCTAssertEqualObjects(message, expected);
                                              index += 1;
                                              if (index < 4) {
                                                id request = [RMTStreamingOutputCallRequest
                                                    messageWithPayloadSize:requests[index]
                                                     requestedResponseSize:responses[index]];
                                                [call writeMessage:request];
                                              } else {
                                                [call finish];
                                              }
                                            }
                                            closeCallback:^(NSDictionary *trailingMetadata,
                                                            NSError *error) {
                                              XCTAssertNil(error,
                                                           @"Finished with unexpected error: %@",
                                                           error);
                                              XCTAssertEqual(index, 4,
                                                             @"Received %i responses instead of 4.",
                                                             index);
                                              [expectation fulfill];
                                            }]
                            callOptions:options];
  [call start];
  [call writeMessage:request];

  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
}

- (void)testLoggingInterceptor {
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"PingPongWithV2API"];

  __block NSUInteger startCount = 0;
  __block NSUInteger writeDataCount = 0;
  __block NSUInteger finishCount = 0;
  __block NSUInteger receiveNextMessageCount = 0;
  __block NSUInteger responseHeaderCount = 0;
  __block NSUInteger responseDataCount = 0;
  __block NSUInteger responseCloseCount = 0;
  __block NSUInteger didWriteDataCount = 0;
  id<GRPCInterceptorFactory> factory = [[HookInterceptorFactory alloc]
      initWithRequestDispatchQueue:dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL)
      responseDispatchQueue:dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL)
      startHook:^(GRPCRequestOptions *requestOptions, GRPCCallOptions *callOptions,
                  GRPCInterceptorManager *manager) {
        startCount++;
        XCTAssertEqualObjects(requestOptions.host, [[self class] host]);
        XCTAssertEqualObjects(requestOptions.path, @"/grpc.testing.TestService/FullDuplexCall");
        XCTAssertEqual(requestOptions.safety, GRPCCallSafetyDefault);
        [manager startNextInterceptorWithRequest:[requestOptions copy]
                                     callOptions:[callOptions copy]];
      }
      writeDataHook:^(id data, GRPCInterceptorManager *manager) {
        writeDataCount++;
        [manager writeNextInterceptorWithData:data];
      }
      finishHook:^(GRPCInterceptorManager *manager) {
        finishCount++;
        [manager finishNextInterceptor];
      }
      receiveNextMessagesHook:^(NSUInteger numberOfMessages, GRPCInterceptorManager *manager) {
        receiveNextMessageCount++;
        [manager receiveNextInterceptorMessages:numberOfMessages];
      }
      responseHeaderHook:^(NSDictionary *initialMetadata, GRPCInterceptorManager *manager) {
        responseHeaderCount++;
        [manager forwardPreviousInterceptorWithInitialMetadata:initialMetadata];
      }
      responseDataHook:^(id data, GRPCInterceptorManager *manager) {
        responseDataCount++;
        [manager forwardPreviousInterceptorWithData:data];
      }
      responseCloseHook:^(NSDictionary *trailingMetadata, NSError *error,
                          GRPCInterceptorManager *manager) {
        responseCloseCount++;
        [manager forwardPreviousInterceptorCloseWithTrailingMetadata:trailingMetadata error:error];
      }
      didWriteDataHook:^(GRPCInterceptorManager *manager) {
        didWriteDataCount++;
        [manager forwardPreviousInterceptorDidWriteData];
      }];

  NSArray *requests = @[ @1, @2, @3, @4 ];
  NSArray *responses = @[ @1, @2, @3, @4 ];

  __block int index = 0;

  id request = [RMTStreamingOutputCallRequest messageWithPayloadSize:requests[index]
                                               requestedResponseSize:responses[index]];
  GRPCMutableCallOptions *options = [[GRPCMutableCallOptions alloc] init];
  options.transportType = [[self class] transportType];
  options.PEMRootCertificates = [[self class] PEMRootCertificates];
  options.hostNameOverride = [[self class] hostNameOverride];
  options.flowControlEnabled = YES;
  options.interceptorFactories = @[ factory ];
  __block BOOL canWriteData = NO;

  __block GRPCStreamingProtoCall *call = [_service
      fullDuplexCallWithResponseHandler:[[InteropTestsBlockCallbacks alloc]
                                            initWithInitialMetadataCallback:nil
                                            messageCallback:^(id message) {
                                              XCTAssertLessThan(index, 4,
                                                                @"More than 4 responses received.");
                                              id expected = [RMTStreamingOutputCallResponse
                                                  messageWithPayloadSize:responses[index]];
                                              XCTAssertEqualObjects(message, expected);
                                              index += 1;
                                              if (index < 4) {
                                                id request = [RMTStreamingOutputCallRequest
                                                    messageWithPayloadSize:requests[index]
                                                     requestedResponseSize:responses[index]];
                                                XCTAssertTrue(canWriteData);
                                                canWriteData = NO;
                                                [call writeMessage:request];
                                                [call receiveNextMessage];
                                              } else {
                                                [call finish];
                                              }
                                            }
                                            closeCallback:^(NSDictionary *trailingMetadata,
                                                            NSError *error) {
                                              XCTAssertNil(error,
                                                           @"Finished with unexpected error: %@",
                                                           error);
                                              XCTAssertEqual(index, 4,
                                                             @"Received %i responses instead of 4.",
                                                             index);
                                              [expectation fulfill];
                                            }
                                            writeMessageCallback:^{
                                              canWriteData = YES;
                                            }]
                            callOptions:options];
  [call start];
  [call receiveNextMessage];
  [call writeMessage:request];

  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
  XCTAssertEqual(startCount, 1);
  XCTAssertEqual(writeDataCount, 4);
  XCTAssertEqual(finishCount, 1);
  XCTAssertEqual(receiveNextMessageCount, 4);
  XCTAssertEqual(responseHeaderCount, 1);
  XCTAssertEqual(responseDataCount, 4);
  XCTAssertEqual(responseCloseCount, 1);
  XCTAssertEqual(didWriteDataCount, 4);
}

// Chain a default interceptor and a hook interceptor which, after two writes, cancels the call
// under the hood but forward further data to the user.
- (void)testHijackingInterceptor {
  NSUInteger kCancelAfterWrites = 2;
  XCTAssertNotNil([[self class] host]);
  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"PingPongWithV2API"];

  NSArray *responses = @[ @1, @2, @3, @4 ];
  __block int index = 0;

  __block NSUInteger startCount = 0;
  __block NSUInteger writeDataCount = 0;
  __block NSUInteger finishCount = 0;
  __block NSUInteger responseHeaderCount = 0;
  __block NSUInteger responseDataCount = 0;
  __block NSUInteger responseCloseCount = 0;
  id<GRPCInterceptorFactory> factory = [[HookInterceptorFactory alloc]
      initWithRequestDispatchQueue:dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL)
      responseDispatchQueue:dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL)
      startHook:^(GRPCRequestOptions *requestOptions, GRPCCallOptions *callOptions,
                  GRPCInterceptorManager *manager) {
        startCount++;
        [manager startNextInterceptorWithRequest:[requestOptions copy]
                                     callOptions:[callOptions copy]];
      }
      writeDataHook:^(id data, GRPCInterceptorManager *manager) {
        writeDataCount++;
        if (index < kCancelAfterWrites) {
          [manager writeNextInterceptorWithData:data];
        } else if (index == kCancelAfterWrites) {
          [manager cancelNextInterceptor];
          [manager forwardPreviousInterceptorWithData:[[RMTStreamingOutputCallResponse
                                                          messageWithPayloadSize:responses[index]]
                                                          data]];
        } else {  // (index > kCancelAfterWrites)
          [manager forwardPreviousInterceptorWithData:[[RMTStreamingOutputCallResponse
                                                          messageWithPayloadSize:responses[index]]
                                                          data]];
        }
      }
      finishHook:^(GRPCInterceptorManager *manager) {
        finishCount++;
        // finish must happen after the hijacking, so directly reply with a close
        [manager forwardPreviousInterceptorCloseWithTrailingMetadata:@{@"grpc-status" : @"0"}
                                                               error:nil];
      }
      receiveNextMessagesHook:nil
      responseHeaderHook:^(NSDictionary *initialMetadata, GRPCInterceptorManager *manager) {
        responseHeaderCount++;
        [manager forwardPreviousInterceptorWithInitialMetadata:initialMetadata];
      }
      responseDataHook:^(id data, GRPCInterceptorManager *manager) {
        responseDataCount++;
        [manager forwardPreviousInterceptorWithData:data];
      }
      responseCloseHook:^(NSDictionary *trailingMetadata, NSError *error,
                          GRPCInterceptorManager *manager) {
        responseCloseCount++;
        // since we canceled the call, it should return cancel error
        XCTAssertNil(trailingMetadata);
        XCTAssertNotNil(error);
        XCTAssertEqual(error.code, GRPC_STATUS_CANCELLED);
      }
      didWriteDataHook:nil];

  NSArray *requests = @[ @1, @2, @3, @4 ];

  id request = [RMTStreamingOutputCallRequest messageWithPayloadSize:requests[index]
                                               requestedResponseSize:responses[index]];
  GRPCMutableCallOptions *options = [[GRPCMutableCallOptions alloc] init];
  options.transportType = [[self class] transportType];
  options.PEMRootCertificates = [[self class] PEMRootCertificates];
  options.hostNameOverride = [[self class] hostNameOverride];
  options.interceptorFactories = @[ [[DefaultInterceptorFactory alloc] init], factory ];

  __block GRPCStreamingProtoCall *call = [_service
      fullDuplexCallWithResponseHandler:[[InteropTestsBlockCallbacks alloc]
                                            initWithInitialMetadataCallback:nil
                                            messageCallback:^(id message) {
                                              XCTAssertLessThan(index, 4,
                                                                @"More than 4 responses received.");
                                              id expected = [RMTStreamingOutputCallResponse
                                                  messageWithPayloadSize:responses[index]];
                                              XCTAssertEqualObjects(message, expected);
                                              index += 1;
                                              if (index < 4) {
                                                id request = [RMTStreamingOutputCallRequest
                                                    messageWithPayloadSize:requests[index]
                                                     requestedResponseSize:responses[index]];
                                                [call writeMessage:request];
                                                [call receiveNextMessage];
                                              } else {
                                                [call finish];
                                              }
                                            }
                                            closeCallback:^(NSDictionary *trailingMetadata,
                                                            NSError *error) {
                                              XCTAssertNil(error,
                                                           @"Finished with unexpected error: %@",
                                                           error);
                                              XCTAssertEqual(index, 4,
                                                             @"Received %i responses instead of 4.",
                                                             index);
                                              [expectation fulfill];
                                            }]
                            callOptions:options];
  [call start];
  [call receiveNextMessage];
  [call writeMessage:request];

  [self waitForExpectationsWithTimeout:TEST_TIMEOUT handler:nil];
  XCTAssertEqual(startCount, 1);
  XCTAssertEqual(writeDataCount, 4);
  XCTAssertEqual(finishCount, 1);
  XCTAssertEqual(responseHeaderCount, 1);
  XCTAssertEqual(responseDataCount, 2);
  XCTAssertEqual(responseCloseCount, 1);
}

@end
