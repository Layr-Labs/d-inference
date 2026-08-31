#pragma once

#import <Foundation/Foundation.h>
#import <bsm/libbsm.h>

NS_ASSUME_NONNULL_BEGIN

bool DBInferenceWorkerCopyAuditToken(NSXPCConnection *connection, audit_token_t *token);

NS_ASSUME_NONNULL_END
