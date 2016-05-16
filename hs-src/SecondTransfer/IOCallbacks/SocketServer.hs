{-# LANGUAGE TemplateHaskell, OverloadedStrings, GeneralizedNewtypeDeriving  #-}
module SecondTransfer.IOCallbacks.SocketServer(
                SocketIOCallbacks
              , TLSServerSocketIOCallbacks                          (..)
              , TLSAcceptResult
              , createAndBindListeningSocket
              , createAndBindListeningSocketNSSockAddr
              , socketIOCallbacks

              -- ** Socket server with callbacks
              , tcpServe
              , tlsServe

              -- ** Socket server with iterators
              , tcpItcli
              --, tlsItcli
       ) where


--import           Control.Concurrent                                 (threadDelay)
import qualified Control.Exception                                  as E
--import           Control.Lens                                       (makeLenses, (^.))
import           Control.Monad.IO.Class                             (liftIO)

import           Data.Conduit
import qualified Data.Conduit.List                                  as CL


import           System.IO.Error                                    (ioeGetErrorString)

import qualified Network.Socket                                     as NS

import           SecondTransfer.IOCallbacks.Types
import           SecondTransfer.IOCallbacks.WrapSocket              (
                                                                     socketIOCallbacks,
                                                                     SocketIOCallbacks,
                                                                     HasSocketPeer(..),
                                                                     AcceptErrorCondition(..)
                                                                     )

#include "instruments.cpphs"


-- | Simple alias to SocketIOCallbacks where we expect
--   encrypted contents
newtype TLSServerSocketIOCallbacks = TLSServerSocketIOCallbacks SocketIOCallbacks
    deriving IOChannels

type TLSAcceptResult = Either AcceptErrorCondition TLSServerSocketIOCallbacks

instance TLSEncryptedIO TLSServerSocketIOCallbacks
instance TLSServerIO TLSServerSocketIOCallbacks

instance HasSocketPeer TLSServerSocketIOCallbacks where
    getSocketPeerAddress (TLSServerSocketIOCallbacks s) = getSocketPeerAddress s

-- | Creates a listening socket at the provided network address (potentially a local interface)
--   and the given port number. It returns the socket. This result can be used by the function
--   tcpServe below
createAndBindListeningSocket :: String -> Int ->  IO NS.Socket
createAndBindListeningSocket hostname portnumber = do
    the_socket <- NS.socket NS.AF_INET NS.Stream NS.defaultProtocol
    addr_info0 : _ <- NS.getAddrInfo Nothing (Just hostname) Nothing
    addr_info1  <- return $ addr_info0 {
        NS.addrFamily = NS.AF_INET
      , NS.addrSocketType = NS.Stream
      , NS.addrAddress =
          (\ (NS.SockAddrInet _ a) -> NS.SockAddrInet (fromIntegral portnumber) a)
              (NS.addrAddress addr_info0)
        }
    host_address <- return $ NS.addrAddress addr_info1

#ifndef WIN32
    NS.setSocketOption the_socket NS.ReusePort 1
#endif
    NS.setSocketOption the_socket NS.RecvBuffer 32000
    NS.setSocketOption the_socket NS.SendBuffer 32000
    -- Linux honors the Low Water thingy below, and this setting is OK for HTTP/2 connections, but
    -- not very needed since the TLS wrapping will inflate the packet well beyond that size.
    -- See about this option here: http://stackoverflow.com/questions/8245937/whats-the-purpose-of-the-socket-option-so-sndlowat
    --
    -- NS.setSocketOption the_socket NS.RecvLowWater 8
    --
    NS.setSocketOption the_socket NS.NoDelay 1
    NS.bind the_socket host_address
    NS.listen the_socket 20
    -- bound <- NS.isBound the_socket
    return the_socket

-- | Same as above, but it takes a pre-built address
createAndBindListeningSocketNSSockAddr :: NS.SockAddr ->  IO NS.Socket
createAndBindListeningSocketNSSockAddr host_addr = do
    the_socket <- case host_addr of
        NS.SockAddrInet _ _ -> NS.socket NS.AF_INET NS.Stream NS.defaultProtocol
        NS.SockAddrUnix _ -> NS.socket NS.AF_UNIX NS.Stream NS.defaultProtocol
        _ -> error "NetworkAddressTypeNotHandled"
#ifndef WIN32
    NS.setSocketOption the_socket NS.ReusePort 1
#endif
    NS.setSocketOption the_socket NS.RecvBuffer 64000
    NS.setSocketOption the_socket NS.SendBuffer 64000
    -- Linux honors the Low Water thingy below, and this setting is OK for HTTP/2 connections, but
    -- not very needed since the TLS wrapping will inflate the packet well beyond that size.
    -- See about this option here: http://stackoverflow.com/questions/8245937/whats-the-purpose-of-the-socket-option-so-sndlowat
    --
    -- NS.setSocketOption the_socket NS.RecvLowWater 8
    --
    NS.setSocketOption the_socket NS.NoDelay 1
    NS.bind the_socket host_addr
    NS.listen the_socket 20
    -- bound <- NS.isBound the_socket
    return the_socket


-- | Simple TCP server. You must give a very short action, as the action
--   is run straight in the calling thread.
--   For a typical server, you would be doing a forkIO in the provided action.
--   Do prefer to use tcpItcli directly.
tcpServe :: NS.Socket -> (Either AcceptErrorCondition NS.Socket -> IO () ) -> IO ()
tcpServe  listen_socket action =
    tcpItcli listen_socket $$
       CL.mapM_
           (\ either_condition_or_pair ->
               case either_condition_or_pair of
                   Left condition -> action $ Left condition
                   Right (a,_b) -> action $ Right a
           )


-- | Itcli is a word made from "ITerate-on-CLIents". This function makes an iterated
--   listen...
tcpItcli :: NS.Socket -> Source IO (Either AcceptErrorCondition  (NS.Socket, NS.SockAddr) )
tcpItcli listen_socket =
    -- NOTICE: The messages below should be considered traps. Whenever one
    -- of them shows up, we have hit a new abnormal condition that should
    -- be learn from
    do
        let
          report_abnormality = do
              putStrLn "ERROR: TCP listen abstraction undone!!"
          -- TODO: System interrupts propagates freely!
          iterate' = do
              either_x <- liftIO . E.try $ NS.accept listen_socket
              case either_x of
                  Left e  | ioeGetErrorString e  == "resource exhausted" -> do
                              yield . Left $ ResourceExhausted_AEC
                              iterate'
                          | s <- ioeGetErrorString e  -> do
                              yield . Left $ Misc_AEC s
                              iterate'
                  Right  (new_socket, sock_addr) -> do
                      yieldOr  (Right  (new_socket, sock_addr)) report_abnormality
                      iterate'
        iterate'


-- | Convenience function to create a TLS server. You are in charge of actually setting
--   up the TLS session, this only receives a type tagged with the IO thing...
--   Notice that the action should be short before actually forking towards something doing
--   the rest of the conversation. If you do the TLS handshake in this thread, you will be in
--   trouble when more than one client try to handshake simultaeneusly... ibidem if one of the
--   clients blocks the handshake.
tlsServe :: NS.Socket ->  ( TLSAcceptResult -> IO () ) -> IO ()
tlsServe listen_socket tls_action =
    tcpServe listen_socket tcp_action
  where
    tcp_action either_active_socket =
      case either_active_socket of
          Left condition ->
              tls_action $ Left condition

          Right active_socket ->
            do
              socket_io_callbacks <- socketIOCallbacks active_socket
              tls_action $
                  Right (TLSServerSocketIOCallbacks socket_io_callbacks)


-- tlsItcli :: NS.Socket -> Source IO (TLSServerSocketIOCallbacks, NS.SockAddr)
-- tlsItcli listen_socket =
--     fuse
--         (tcpItcli listen_socket)
--         ( CL.mapM
--             $ \ (active_socket, address) -> do
--                 socket_io_callbacks <- socketIOCallbacks active_socket
--                 return (TLSServerSocketIOCallbacks socket_io_callbacks ,address)
--         )
