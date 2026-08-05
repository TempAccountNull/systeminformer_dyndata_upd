/*
 * Copyright (c) 2022 Winsider Seminars & Solutions, Inc.  All rights reserved.
 *
 * This file is part of System Informer.
 *
 * Authors:
 *
 *     OpenAI   2026
 *
 */

#include <kphdynverify.h>

#include <bcrypt.h>

#define KPH_DYN_HASH_LENGTH (512 / 8)

#ifdef ALLOC_PRAGMA
#pragma alloc_text(PAGE, KphDynVerifySignature)
#endif

_IRQL_requires_max_(PASSIVE_LEVEL)
_Must_inspect_result_
NTSTATUS KphDynVerifySignature(
    _In_reads_bytes_(PublicKeyLength) const UCHAR* PublicKey,
    _In_ ULONG PublicKeyLength,
    _In_reads_bytes_(BufferLength) const UCHAR* Buffer,
    _In_ ULONG BufferLength,
    _In_reads_bytes_(SignatureLength) const UCHAR* Signature,
    _In_ ULONG SignatureLength
    )
{
    NTSTATUS status;
    BCRYPT_HASH_HANDLE hashHandle;
    BCRYPT_KEY_HANDLE keyHandle;
    BCRYPT_PSS_PADDING_INFO paddingInfo;
    UCHAR hash[KPH_DYN_HASH_LENGTH];

    PAGED_CODE();

    if (!PublicKey || !PublicKeyLength || !Buffer || !BufferLength ||
        !Signature || !SignatureLength)
    {
        return STATUS_INVALID_PARAMETER;
    }

    hashHandle = NULL;
    status = BCryptCreateHash(BCRYPT_SHA512_ALG_HANDLE,
                              &hashHandle,
                              NULL,
                              0,
                              NULL,
                              0,
                              0);
    if (!NT_SUCCESS(status))
    {
        return status;
    }

    status = BCryptHashData(hashHandle,
                            (PUCHAR)Buffer,
                            BufferLength,
                            0);
    if (NT_SUCCESS(status))
    {
        status = BCryptFinishHash(hashHandle,
                                  hash,
                                  sizeof(hash),
                                  0);
    }

    BCryptDestroyHash(hashHandle);
    if (!NT_SUCCESS(status))
    {
        RtlSecureZeroMemory(hash, sizeof(hash));
        return status;
    }

    keyHandle = NULL;
    status = BCryptImportKeyPair(BCRYPT_RSA_ALG_HANDLE,
                                 NULL,
                                 BCRYPT_RSAPUBLIC_BLOB,
                                 &keyHandle,
                                 (PUCHAR)PublicKey,
                                 PublicKeyLength,
                                 0);
    if (!NT_SUCCESS(status))
    {
        RtlSecureZeroMemory(hash, sizeof(hash));
        return status;
    }

    paddingInfo.pszAlgId = BCRYPT_SHA512_ALGORITHM;
    paddingInfo.cbSalt = KPH_DYN_HASH_LENGTH;

    status = BCryptVerifySignature(keyHandle,
                                   &paddingInfo,
                                   hash,
                                   sizeof(hash),
                                   (PUCHAR)Signature,
                                   SignatureLength,
                                   BCRYPT_PAD_PSS);

    BCryptDestroyKey(keyHandle);
    RtlSecureZeroMemory(hash, sizeof(hash));

    return status;
}
