#import "cast.h"
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <openssl/bio.h>
#include <openssl/bn.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/x509v3.h>
#include "util/crypto/certificate_utils.h"

namespace {
bool Extension(X509* certificate, int type, const char* value) {
  bssl::UniquePtr<X509_EXTENSION> extension(
      X509V3_EXT_nconf_nid(nullptr, nullptr, type, value));
  return extension && X509_add_ext(certificate, extension.get(), -1) == 1;
}

bool WritePem(int directory, const char* name, BIO* pem) {
  char* bytes = nullptr;
  const long size = BIO_get_mem_data(pem, &bytes);
  if (size <= 0) return false;
  const int file = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
  if (file < 0) return false;
  long written = 0;
  while (written < size) {
    const ssize_t count = write(file, bytes + written, size - written);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) break;
    written += count;
  }
  const bool success = written == size && fsync(file) == 0;
  const bool closed = close(file) == 0;
  return success && closed;
}

NSString* Generate(NSURL* directory) {
  if (!directory.isFileURL || !directory.path.isAbsolutePath)
    return @"Choose a local folder for the development credentials.";
  const char* path = directory.fileSystemRepresentation;
  if (mkdir(path, 0700) != 0)
    return errno == EEXIST ? @"That credentials folder already exists. Choose a new folder." :
        @"Cannot create the credentials folder. Check the location and write permission.";
  const int folder = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
  if (folder < 0) { rmdir(path); return @"Cannot open the new credentials folder."; }

  bool success = false;
  auto key = openscreen::GenerateRsaKeyPair();
  bssl::UniquePtr<X509> certificate(X509_new());
  bssl::UniquePtr<BIO> certificate_pem(BIO_new(BIO_s_mem()));
  bssl::UniquePtr<BIO> key_pem(BIO_new(BIO_s_mem()));
  uint8_t serial_bytes[16];
  // Independent random serials avoid the sample certificate helper's shared
  // serial counter when another receiver is generating its device credentials.
  bssl::UniquePtr<BIGNUM> serial(BN_new());
  static const unsigned char name[] = "Applescreen Local Development Root";
  if (key && certificate && certificate_pem && key_pem && serial &&
      RAND_bytes(serial_bytes, sizeof(serial_bytes)) == 1 &&
      BN_bin2bn(serial_bytes, sizeof(serial_bytes), serial.get()) &&
      BN_to_ASN1_INTEGER(serial.get(), X509_get_serialNumber(certificate.get())) &&
      X509_set_version(certificate.get(), 2) == 1 &&
      X509_gmtime_adj(X509_getm_notBefore(certificate.get()), -60) &&
      X509_gmtime_adj(X509_getm_notAfter(certificate.get()), 365L * 24 * 60 * 60) &&
      X509_NAME_add_entry_by_txt(X509_get_subject_name(certificate.get()), "CN",
          MBSTRING_ASC, name, -1, -1, 0) == 1 &&
      X509_set_issuer_name(certificate.get(), X509_get_subject_name(certificate.get())) == 1 &&
      X509_set_pubkey(certificate.get(), key.get()) == 1 &&
      Extension(certificate.get(), NID_basic_constraints, "critical,CA:TRUE") &&
      Extension(certificate.get(), NID_key_usage, "critical,digitalSignature,keyCertSign,cRLSign") &&
      X509_sign(certificate.get(), key.get(), EVP_sha256()) > 0 &&
      X509_verify(certificate.get(), key.get()) == 1 &&
      PEM_write_bio_X509(certificate_pem.get(), certificate.get()) == 1 &&
      PEM_write_bio_PrivateKey(key_pem.get(), key.get(), nullptr, nullptr, 0, nullptr, nullptr) == 1) {
    success = WritePem(folder, "development-ca.key", key_pem.get()) &&
              WritePem(folder, "development-ca.crt", certificate_pem.get());
  }
  if (!success) {
    unlinkat(folder, "development-ca.key", 0);
    unlinkat(folder, "development-ca.crt", 0);
  }
  close(folder);
  if (!success) rmdir(path);
  return success ? nil : @"Could not generate and save development credentials. Check free space and folder permissions.";
}
}  // namespace

void ASCastGenerateDeveloperCA(CFURLRef directory, ASCastCredentialsCallback callback, void* context) {
  NSURL* destination = directory && CFGetTypeID(directory) == CFURLGetTypeID() ?
      [(__bridge NSURL*)directory copy] : nil;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      NSString* error = Generate(destination);
      dispatch_async(dispatch_get_main_queue(), ^{
        if (callback) callback(context, (__bridge CFStringRef)error);
      });
    }
  });
}
