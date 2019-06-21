{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}

-- | Serialization primitives built on top of the @ToCBOR@ typeclass

module Cardano.Binary.Serialize
  ( serialize
  , serialize'
  , serializeBuilder
  , serializeEncoding

  -- * CBOR in CBOR
  , encodeKnownCborDataItem
  , encodeUnknownCborDataItem
  , knownCborDataItemSizeExpr
  , unknownCborDataItemSizeExpr

  -- * Cyclic redundancy check
  , encodeCrcProtected
  , encodedCrcProtectedSizeExpr
  )
where

import Cardano.Prelude

import qualified Codec.CBOR.Write as CBOR.Write
import Data.ByteString.Builder (Builder)
import qualified Data.ByteString.Builder.Extra as Builder
import qualified Data.ByteString.Lazy as BSL
import Data.Digest.CRC32 (CRC32(..))

import Cardano.Binary.ToCBOR
  (Encoding, Size, ToCBOR(..), apMono, encodeListLen, encodeTag, withWordSize)


-- | Serialize a Haskell value with a 'ToCBOR' instance to an external binary
--   representation.
--
--   The output is represented as a lazy 'LByteString' and is constructed
--   incrementally.
serialize :: ToCBOR a => a -> LByteString
serialize = serializeEncoding . toCBOR

-- | Serialize a Haskell value to an external binary representation.
--
--   The output is represented as a strict 'ByteString'.
serialize' :: ToCBOR a => a -> ByteString
serialize' = BSL.toStrict . serialize

-- | Serialize into a Builder. Useful if you want to throw other ByteStrings
--   around it.
serializeBuilder :: ToCBOR a => a -> Builder
serializeBuilder = CBOR.Write.toBuilder . toCBOR

-- | Serialize a Haskell value to an external binary representation using the
--   provided CBOR 'Encoding'
--
--   The output is represented as an 'LByteString' and is constructed
--   incrementally.
serializeEncoding :: Encoding -> LByteString
serializeEncoding =
  Builder.toLazyByteStringWith strategy mempty . CBOR.Write.toBuilder
  where
    -- 1024 is the size of the first buffer, 4096 is the size of subsequent
    -- buffers. Chosen because they seem to give good performance. They are not
    -- sacred.
        strategy = Builder.safeStrategy 1024 4096

--------------------------------------------------------------------------------
-- CBORDataItem
-- https://tools.ietf.org/html/rfc7049#section-2.4.4.1
--------------------------------------------------------------------------------

-- | Encode and serialise the given `a` and sorround it with the semantic tag 24
--   In CBOR diagnostic notation:
--   >>> 24(h'DEADBEEF')
encodeKnownCborDataItem :: ToCBOR a => a -> Encoding
encodeKnownCborDataItem = encodeUnknownCborDataItem . serialize

-- | Like `encodeKnownCborDataItem`, but assumes nothing about the shape of
--   input object, so that it must be passed as a binary `ByteString` blob. It's
--   the caller responsibility to ensure the input `ByteString` correspond
--   indeed to valid, previously-serialised CBOR data.
encodeUnknownCborDataItem :: LByteString -> Encoding
encodeUnknownCborDataItem x = encodeTag 24 <> toCBOR x

knownCborDataItemSizeExpr :: Size -> Size
knownCborDataItemSizeExpr x = 2 + apMono "withWordSize" withWordSize x + x

unknownCborDataItemSizeExpr :: Size -> Size
unknownCborDataItemSizeExpr x = 2 + apMono "withWordSize" withWordSize x + x

-- | Encodes a type `a` , protecting it from
--   tampering/network-transport-alteration by protecting it with a CRC.
encodeCrcProtected :: ToCBOR a => a -> Encoding
encodeCrcProtected x =
  encodeListLen 2 <> encodeUnknownCborDataItem body <> toCBOR (crc32 body)
  where body = serialize x

encodedCrcProtectedSizeExpr
  :: forall a
   . ToCBOR a
  => (forall t . ToCBOR t => Proxy t -> Size)
  -> Proxy a
  -> Size
encodedCrcProtectedSizeExpr size pxy =
  2 + unknownCborDataItemSizeExpr (size pxy) + size
    (pure $ crc32 (serialize (panic "unused" :: a)))
