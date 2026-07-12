#ifndef AWG_X25519_H
#define AWG_X25519_H

void awg_curve25519_derive_public_key(unsigned char public_key[32], const unsigned char private_key[32]);
void awg_curve25519_generate_private_key(unsigned char private_key[32]);

#endif
