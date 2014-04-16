{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

------------------------------------------------------------------------------
module Snap.Internal.Http.Server.TLS
  ( TLSException
  , withTLS
  , bindHttps
  , httpsAcceptFunc
  , sendFileFunc
  ) where

------------------------------------------------------------------------------
import           Control.Exception                 (Exception, throwIO)
import           Data.ByteString.Char8             (ByteString)
import           Data.Typeable                     (Typeable)
import           Network.Socket                    (Socket)
#ifdef OPENSSL
import           Blaze.ByteString.Builder          (fromByteString)
import           Control.Monad                     (when)
import qualified Network.Socket                    as Socket
import           OpenSSL                           (withOpenSSL)
import           OpenSSL.Session                   (SSL, SSLContext)
import qualified OpenSSL.Session                   as SSL
import           Prelude                           (FilePath, IO, Int, Maybe (..), Monad (..), Show, String, fromIntegral, id, not, ($), ($!), (++))
import           Snap.Internal.Http.Server.Address (getAddress, getSockAddr)
import qualified System.IO.Streams                 as Streams
import qualified System.IO.Streams.SSL             as SStreams
#else
import           Prelude                           (FilePath, IO, Int, Show, String, id, ($))
#endif
------------------------------------------------------------------------------
import           Snap.Internal.Http.Server.Types   (AcceptFunc (..), SendFileHandler)
------------------------------------------------------------------------------

data TLSException = TLSException String
  deriving (Show, Typeable)
instance Exception TLSException

#ifndef OPENSSL
type SSLContext = ()
type SSL = ()

------------------------------------------------------------------------------
withTLS :: IO a -> IO a
withTLS = id


------------------------------------------------------------------------------
barf :: IO a
barf = throwIO $
       TLSException "TLS is not supported, build snap-server with -fopenssl"


------------------------------------------------------------------------------
bindHttps :: ByteString -> Int -> FilePath -> FilePath -> IO Socket
bindHttps _ _ _ _ = barf


------------------------------------------------------------------------------
httpsAcceptFunc :: Socket -> SSLContext -> AcceptFunc
httpsAcceptFunc _ _ = AcceptFunc $ \restore -> restore barf


------------------------------------------------------------------------------
sendFileFunc :: SSL -> Socket -> SendFileHandler
sendFileFunc _ _ _ _ _ _ _ = barf

#else
------------------------------------------------------------------------------
withTLS :: IO a -> IO a
withTLS = withOpenSSL


------------------------------------------------------------------------------
bindHttps :: ByteString
          -> Int
          -> FilePath
          -> FilePath
          -> IO (Socket, SSLContext)
bindHttps bindAddress bindPort cert key = do
    (family, addr) <- getSockAddr bindPort bindAddress
    sock           <- Socket.socket family Socket.Stream 0

    Socket.setSocketOption sock Socket.ReuseAddr 1
    Socket.bindSocket sock addr
    Socket.listen sock 150

    ctx <- SSL.context
    SSL.contextSetPrivateKeyFile  ctx key
    SSL.contextSetCertificateFile ctx cert
    SSL.contextSetDefaultCiphers  ctx

    certOK <- SSL.contextCheckPrivateKey ctx
    when (not certOK) $ throwIO $ TLSException certificateError
    return (sock, ctx)

  where
    certificateError = "OpenSSL says that the certificate " ++
                       "doesn't match the private key!"


------------------------------------------------------------------------------
httpsAcceptFunc :: (Socket, SSLContext)
                -> AcceptFunc
httpsAcceptFunc (boundSocket, ctx) = AcceptFunc $ \restore -> do
    (sock, remoteAddr)       <- restore (Socket.accept boundSocket)
    localAddr                <- Socket.getSocketName sock
    (localPort, localHost)   <- getAddress localAddr
    (remotePort, remoteHost) <- getAddress remoteAddr
    ssl                      <- restore (SSL.connection ctx sock)

    restore (SSL.accept ssl)
    (readEnd, writeEnd) <- SStreams.sslToStreams ssl

    let cleanup = do Streams.write Nothing writeEnd
                     SSL.shutdown ssl SSL.Unidirectional
                     Socket.close sock

    return $! ( sendFileFunc ssl
              , localHost
              , localPort
              , remoteHost
              , remotePort
              , readEnd
              , writeEnd
              , cleanup
              )

------------------------------------------------------------------------------
sendFileFunc :: SSL -> SendFileHandler
sendFileFunc ssl buffer builder fPath offset nbytes =
    Streams.unsafeWithFileAsInputStartingAt (fromIntegral offset) fPath $ \fileInput0 -> do
        fileInput <- Streams.takeBytes (fromIntegral nbytes) fileInput0 >>=
                     Streams.map fromByteString
        input     <- Streams.fromList [builder] >>=
                     Streams.appendInputStream fileInput
        output    <- Streams.makeOutputStream sendChunk >>=
                     Streams.unsafeBuilderStream (return buffer)
        Streams.connect input output

  where
    sendChunk (Just s) = SSL.write ssl s
    sendChunk Nothing  = return $! ()
#endif
