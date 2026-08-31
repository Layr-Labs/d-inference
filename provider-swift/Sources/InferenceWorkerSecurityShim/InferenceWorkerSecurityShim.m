#import "InferenceWorkerSecurityShim.h"

@interface NSXPCConnection (DBInferenceWorkerAuditToken)
@property(nonatomic, readonly) audit_token_t auditToken;
@end

bool DBInferenceWorkerCopyAuditToken(NSXPCConnection *connection, audit_token_t *token) {
    if (connection == nil || token == NULL || ![connection respondsToSelector:@selector(auditToken)]) {
        return false;
    }
    *token = connection.auditToken;
    return true;
}
