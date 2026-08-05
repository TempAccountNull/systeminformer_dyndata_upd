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

#pragma once

#include <ntifs.h>

_IRQL_requires_max_(PASSIVE_LEVEL)
_Must_inspect_result_
NTSTATUS KphDynVerifySignature(
    _In_reads_bytes_(PublicKeyLength) const UCHAR* PublicKey,
    _In_ ULONG PublicKeyLength,
    _In_reads_bytes_(BufferLength) const UCHAR* Buffer,
    _In_ ULONG BufferLength,
    _In_reads_bytes_(SignatureLength) const UCHAR* Signature,
    _In_ ULONG SignatureLength
    );
