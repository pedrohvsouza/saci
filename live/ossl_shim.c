#include <openssl/ssl.h>
#include <openssl/evp.h>
#ifdef SSL_get_peer_certificate
#undef SSL_get_peer_certificate
#endif
#ifdef EVP_MD_size
#undef EVP_MD_size
#endif
X509 *SSL_get_peer_certificate(const SSL *ssl) { return SSL_get1_peer_certificate(ssl); }
int EVP_MD_size(const EVP_MD *md) { return EVP_MD_get_size(md); }
