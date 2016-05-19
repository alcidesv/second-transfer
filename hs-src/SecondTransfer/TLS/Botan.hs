{-# LANGUAGE ForeignFunctionInterface, TemplateHaskell, Rank2Types, FunctionalDependencies, OverloadedStrings #-}
module SecondTransfer.TLS.Botan (
                  BotanTLSContext
                , BotanSession
                , unencryptChannelData
                , newBotanTLSContext
                , newBotanTLSContextFromMemory
                , botanTLS
       ) where

import           Control.Concurrent
import qualified Control.Exception                                         as E
import           Control.Monad                                             (unless)
import           Foreign
import           Foreign.C.Types                                           (CChar, CInt(..), CUInt(..))
import           Foreign.C.String                                          (CString)

--import           Data.List                                                 (elemIndex)
import           Data.Tuple                                                (swap)
import           Data.Typeable                                             (Proxy(..))
import           Data.Maybe                                                (fromMaybe)
import           Data.IORef
import qualified Data.ByteString                                           as B
import qualified Data.ByteString.Builder                                   as Bu
import qualified Data.ByteString.Lazy                                      as LB
import qualified Data.ByteString.Unsafe                                    as Un

import           Control.Lens                                              ( (^.), makeLenses,
                                                                             --set, Lens'
                                                                           )

import           System.IO.Unsafe                                          (unsafePerformIO)

-- Import all of it!
import           SecondTransfer.IOCallbacks.Types
import           SecondTransfer.Exception                                  (
                                                                             IOProblem
                                                                           , NoMoreDataException(..)
                                                                           , TLSEncodingIssue (..)
                                                                           , keyedReportExceptions
                                                                           )
import           SecondTransfer.TLS.Types                                  ( ProtocolSelector
                                                                           , TLSContext (..) )

#include "instruments.cpphs"

data BotanTLSChannel

type RawFilePath = B.ByteString

type BotanTLSChannelPtr = Ptr BotanTLSChannel

type BotanTLSChannelFPtr = ForeignPtr BotanTLSChannel

data BotanPad = BotanPad {
    _encryptedSide_BP      :: IOCallbacks
  , _availableData_BP      :: IORef Bu.Builder
  , _tlsChannel_BP         :: IORef BotanTLSChannelFPtr
  , _dataCame_BP           :: MVar ()
  , _handshakeCompleted_BP :: MVar ()
  , _writeLock_BP          :: MVar ()
  , _active_BP             :: MVar ()
  , _protocolSelector_BP   :: B.ByteString -> IO (Int, B.ByteString)
  , _selectedProtocol_BP   :: MVar (Maybe (B.ByteString, Int))
  , _problem_BP            :: MVar ()
    }

type BotanPadRef = StablePtr BotanPad

makeLenses ''BotanPad

newtype BotanSession = BotanSession (IORef BotanPad)

data BotanTLSContextAbstract

type BotanTLSContextCSidePtr = Ptr BotanTLSContextAbstract

type BotanTLSContextCSideFPtr = ForeignPtr BotanTLSContextAbstract

data BotanTLSContext = BotanTLSContext {
    _cppSide_BTC          :: BotanTLSContextCSideFPtr
  , _protocolSelector_BTC :: ProtocolSelector
    }

makeLenses ''BotanTLSContext


-- withBotanPadLock :: Lens' BotanPad (MVar ()) -> BotanPadRef -> (BotanPad -> IO a) -> IO a
-- withBotanPadLock lock_getter siocb cb = do
--     botan_pad <- deRefStablePtr siocb
--     let
--         lock_mvar = botan_pad ^. lock_getter
--     withMVar lock_mvar $ \ _ -> cb botan_pad

withBotanPad :: BotanPadRef -> (BotanPad -> IO a) -> IO a
withBotanPad siocb cb = do
    botan_pad <- deRefStablePtr siocb
    cb botan_pad


dontMultiThreadBotan :: MVar ()
{-# NOINLINE dontMultiThreadBotan #-}
dontMultiThreadBotan = unsafePerformIO $ do
    a <- mk_iocba_push iocba_push
    b <- mk_iocba_data_cb iocba_data_cb
    c <- mk_iocba_alert_cb iocba_alert_cb
    -- d <- mk_iocba_handshake_cb iocba_handshake_cb
    e <- mk_iocba_select_protocol_cb iocba_select_protocol_cb
    iocba_init_callbacks a b c e
    newMVar ()

-- withBotanPadReadLock :: BotanPadRef -> (BotanPad -> IO () ) -> IO ()
-- withBotanPadReadLock = withBotanPadLock readLock_BP

-- withBotanPadWriteLock :: BotanPadRef -> (BotanPad -> IO () ) -> IO ()
-- withBotanPadWriteLock = withBotanPadLock writeLock_BP


type F_iocba_push =  BotanPadRef -> Ptr CChar -> CInt -> IO ()
foreign export ccall iocba_push :: F_iocba_push

-- |Botan calls this function whenever it wishes to send any data
-- to the remote peer. In some cases we can not honor Botan's wishes
iocba_push :: BotanPadRef -> Ptr CChar -> CInt -> IO ()
iocba_push siocb p len =
    withBotanPad siocb $ \ botan_pad ->  do
        let
            push_action = botan_pad ^.  (encryptedSide_BP . pushAction_IOC )
            cstr = (p, fromIntegral len)
            problem_mvar = botan_pad ^. problem_BP
            handler :: IOProblem -> IO ()
            handler _ = do
                _ <- tryPutMVar problem_mvar ()
                _ <- tryPutMVar (botan_pad ^. dataCame_BP) ()
                return ()
        b <- B.packCStringLen cstr
        problem <- tryReadMVar problem_mvar
        case problem of
            Nothing ->
                keyedReportExceptions "iocba_push" $ E.catch
                   (push_action (LB.fromStrict b))
                   handler

            Just _ -> do
                -- Ignore, but don't send any data
                --putStrLn "IGNORED DATA SEND ON ENCR SOCKET"
                return ()

-- | Used to pass callbacks to the C/C++ code
foreign import ccall "wrapper"
    mk_iocba_push :: F_iocba_push -> IO (FunPtr F_iocba_push)

type F_iocba_data_cb = BotanPadRef -> Ptr CChar -> CInt -> IO ()
-- | Callback invoked by Botan with clear text data just decoded from the stream
foreign export ccall iocba_data_cb :: F_iocba_data_cb
iocba_data_cb :: BotanPadRef -> Ptr CChar -> CInt -> IO ()
iocba_data_cb siocb p len = withBotanPad siocb $ \ botan_pad -> do
    let
        cstr = (p, fromIntegral len)
        avail_data = botan_pad ^. availableData_BP
    b <- B.packCStringLen cstr
    if B.length b > 0
      then do
          atomicModifyIORef' avail_data $ \ previous -> ( previous `mappend` (Bu.byteString b), ())
          --putStrLn "Got data"
          _ <- tryPutMVar (botan_pad ^. dataCame_BP) ()
          return ()
      else do
          -- Shouldn't ever happen
          putStrLn "EmptyStringGot"
          return ()

foreign import ccall "wrapper"
    mk_iocba_data_cb :: F_iocba_data_cb -> IO (FunPtr F_iocba_data_cb)


-- TODO: Should we raise some sort of exception here? Maybe call the "closeAction"
-- in the other sides?
type F_iocba_alert_cb = BotanPadRef -> CInt -> IO ()
foreign export ccall iocba_alert_cb :: F_iocba_alert_cb
iocba_alert_cb :: BotanPadRef -> CInt -> IO ()
iocba_alert_cb siocb alert_code = withBotanPad siocb $ \botan_pad -> do
    let
        problem_mvar = botan_pad ^. problem_BP
    putStrLn $ "tls alert " ++ (show alert_code)
    if (alert_code < 0)
          then do
             _ <- tryPutMVar problem_mvar ()
             _ <- tryPutMVar (botan_pad ^. dataCame_BP) ()
             return ()
          else
             return ()
foreign import ccall "wrapper"
    mk_iocba_alert_cb :: F_iocba_alert_cb -> IO (FunPtr F_iocba_alert_cb)


-- Botan relies a wealth of information here, not using at the moment :-(
-- type F_iocba_handshake_cb = BotanPadRef -> IO ()
-- foreign export ccall iocba_handshake_cb :: F_iocba_handshake_cb
-- iocba_handshake_cb :: F_iocba_handshake_cb
-- iocba_handshake_cb siocb = do
--     withBotanPad siocb $ \botan_pad -> do
--         let
--             hcmvar = botan_pad ^. handshakeCompleted_BP
--         _ <-tryPutMVar hcmvar ()
--         maybe_protocol <- tryReadMVar (botan_pad ^. selectedProtocol_BP)

--         -- If by this time no ALPN has completed, signal that
--         case maybe_protocol of
--             Nothing -> do
--                 putMVar (botan_pad ^. selectedProtocol_BP ) Nothing
--             Just _something -> do
--                 -- It's already in the var
--                 return ()
--         return ()

-- foreign import ccall "wrapper"
--     mk_iocba_handshake_cb :: F_iocba_handshake_cb -> IO (FunPtr F_iocba_handshake_cb)

type F_iocba_select_protocol_cb = BotanPadRef -> Ptr CChar -> Int -> IO Int
foreign export ccall iocba_select_protocol_cb :: F_iocba_select_protocol_cb
iocba_select_protocol_cb :: F_iocba_select_protocol_cb
iocba_select_protocol_cb siocb p len =
    withBotanPad siocb $ \ botan_pad -> do
        let
            cstr = (p, fromIntegral len)
            selector = botan_pad ^. protocolSelector_BP
        b <- B.packCStringLen cstr
        (chosen_protocol_int, ss) <- selector b
        let
            selected_protocol_mvar = botan_pad ^. selectedProtocol_BP
        putMVar selected_protocol_mvar (Just (ss, chosen_protocol_int ))
        return chosen_protocol_int

foreign import ccall "wrapper"
    mk_iocba_select_protocol_cb :: F_iocba_select_protocol_cb -> IO (FunPtr F_iocba_select_protocol_cb)


foreign import ccall iocba_cleartext_push ::
  BotanTLSChannelPtr
  -> Ptr CChar
  -> Word32
  -> Ptr CChar
  -> Ptr Word32
  -> IO Int32

foreign import ccall iocba_close :: BotanTLSChannelPtr -> IO ()

foreign import ccall "&iocba_delete_tls_context" iocba_delete_tls_context :: FunPtr( BotanTLSContextCSidePtr -> IO () )

foreign import ccall iocba_make_tls_context :: CString -> CString -> IO BotanTLSContextCSidePtr

foreign import ccall iocba_make_tls_context_from_memory :: CString -> CUInt -> CString -> CUInt -> IO BotanTLSContextCSidePtr

foreign import ccall "&iocba_delete_tls_server_channel" iocba_delete_tls_server_channel :: FunPtr( BotanTLSChannelPtr -> IO () )

--foreign import ccall "wrapper" mkTlsServerDeleter :: (BotanTLSChannelPtr -> IO ()) -> IO (FunPtr ( BotanTLSChannelPtr -> IO () ) )

foreign import ccall iocba_receive_data ::
    BotanTLSChannelPtr ->
    Ptr CChar ->
    Word32 ->
    Ptr CChar ->
    Ptr Word32 ->
    Ptr CChar ->
    Ptr Word32 ->
    IO Int32


foreign import ccall iocba_init_callbacks ::
    FunPtr F_iocba_push ->
    FunPtr F_iocba_data_cb ->
    FunPtr F_iocba_alert_cb ->
    -- FunPtr F_iocba_handshake_cb ->
    FunPtr F_iocba_select_protocol_cb ->
    IO ()



botanPushData :: BotanPad -> LB.ByteString -> IO ()
botanPushData botan_pad datum = do
    let
        strict_datum = LB.toStrict datum
        reserve_length :: Int
        reserve_length =
            floor ((fromIntegral $ B.length strict_datum) * 1.2 + 4096.0 :: Double)
        write_lock = botan_pad ^. writeLock_BP
        channel_ioref = botan_pad ^. tlsChannel_BP
        problem_mvar = botan_pad ^. problem_BP
        handshake_completed_mvar = botan_pad ^. handshakeCompleted_BP

    -- We are doing a lot of locking here... is it all needed?
    readMVar handshake_completed_mvar
    channel <- readIORef channel_ioref
    data_to_send <- withMVar write_lock $ \ _ -> do
        mp <- tryReadMVar problem_mvar
        case mp of
            Nothing ->
                allocaBytes reserve_length $ \ out_enc_to_send -> do
                  alloca $ \ p_enc_to_send_length -> do
                    poke p_enc_to_send_length (fromIntegral reserve_length)
                    Un.unsafeUseAsCStringLen strict_datum $ \ (cleartext_pch, cleartext_len) ->
                      withForeignPtr channel $ \ c -> withMVar dontMultiThreadBotan . const $ do
                         push_result <- iocba_cleartext_push
                             c
                             cleartext_pch
                             (fromIntegral cleartext_len)
                             out_enc_to_send
                             p_enc_to_send_length
                         if push_result < 0
                            then E.throwIO TLSEncodingIssue
                            else do
                                enc_to_send_length <- peek p_enc_to_send_length
                                B.packCStringLen (out_enc_to_send, fromIntegral enc_to_send_length)


            Just _ -> do
                --(botan_pad ^. encryptedSide_BP . closeAction_IOC )
                --putStrLn "bpRaise"
                E.throwIO $ NoMoreDataException

    (botan_pad ^. encryptedSide_BP . pushAction_IOC) . LB.fromStrict $ data_to_send


-- Bad things will happen if serveral threads are calling this concurrently!!
pullAvailableData :: BotanPad -> Bool -> IO LB.ByteString
pullAvailableData botan_pad can_wait = do
    let
        data_came_mvar = botan_pad ^. dataCame_BP
        avail_data_iorref = botan_pad ^. availableData_BP
        io_problem_mvar = botan_pad ^. problem_BP
        -- And here inside cleanup. The block below doesn't compose with other instances of
        -- reads happening simultaneously
    avail_data <- atomicModifyIORef' avail_data_iorref $ \ bu -> (mempty, bu)
    let
        avail_data_lb = Bu.toLazyByteString avail_data
    case ( LB.length avail_data_lb == 0 , can_wait ) of
        (True, True) -> do
            -- Just wait for more data coming here
            takeMVar data_came_mvar
            maybe_problem <- tryReadMVar io_problem_mvar
            case maybe_problem of
                Nothing ->
                        pullAvailableData botan_pad True

                Just () -> do
                    -- avail_data' <- atomicModifyIORef' avail_data_iorref $ \ bu -> (mempty, bu)
                    -- putStrLn "ProblemTranslated -- Botan"
                    -- putStrLn $ "(stuck: " ++ (show .  LB.length . Bu.toLazyByteString $ avail_data' ) ++ ")"
                    E.throwIO NoMoreDataException

        (_, _) -> do
            let
                result =  avail_data_lb
            -- putStrLn $ "BotanPassingUp #bytes = " ++ (show $ B.length result )
            return result


foreign import ccall iocba_new_tls_server_channel ::
        BotanTLSContextCSidePtr
     -> IO BotanTLSChannelPtr

-- TODO: Move this to "SecondTransfer.TLS.Utils" module
protocolSelectorToC :: ProtocolSelector -> B.ByteString -> IO (Int, B.ByteString)
protocolSelectorToC prot_sel flat_protocols = do
    let
        protocol_list =  B.split 0 flat_protocols
    maybe_idx <- prot_sel protocol_list
    let
        report_idx = fromMaybe (-1) maybe_idx
        report_bs = if report_idx >= 0 then protocol_list !! report_idx else "<no-protocol>"
    return (report_idx, report_bs)


newBotanTLSContext :: RawFilePath -> RawFilePath -> ProtocolSelector ->  IO BotanTLSContext
newBotanTLSContext cert_filename privkey_filename prot_sel =
    withMVar dontMultiThreadBotan $ \ _ ->  do
        B.useAsCString cert_filename $ \ s1 ->
            B.useAsCString privkey_filename $ \ s2 -> do
                ctx_ptr <-  iocba_make_tls_context s1 s2
                x <- newForeignPtr iocba_delete_tls_context ctx_ptr
                return $ BotanTLSContext x prot_sel


newBotanTLSContextFromMemory :: B.ByteString -> B.ByteString -> ProtocolSelector -> IO BotanTLSContext
newBotanTLSContextFromMemory cert_data key_data prot_sel =
    withMVar dontMultiThreadBotan $ \ _ ->   do
        B.useAsCString cert_data $ \ s1 ->
          B.useAsCString key_data $ \s2 -> do
              ctx_ptr <- iocba_make_tls_context_from_memory
                             s1
                             (fromIntegral . B.length $ cert_data)
                             s2
                             (fromIntegral . B.length $ key_data)
              x <- newForeignPtr iocba_delete_tls_context ctx_ptr
              return $ BotanTLSContext x prot_sel


unencryptChannelData :: TLSServerIO a =>  BotanTLSContext -> a -> IO  BotanSession
unencryptChannelData botan_ctx tls_data  = do
    let
        fctx = botan_ctx ^. cppSide_BTC
        protocol_selector = botan_ctx ^. protocolSelector_BTC

    tls_io_callbacks <- handshake tls_data
    data_came_mvar <- newEmptyMVar
    handshake_completed_mvar <- newEmptyMVar
    problem_mvar <- newEmptyMVar
    selected_protocol_mvar <- newEmptyMVar
    active_mvar <- newMVar ()
    tls_channel_ioref <- newIORef (error "")
    avail_data_ioref <- newIORef ""
    write_lock_mvar <- newMVar ()

    let
        new_botan_pad = BotanPad {
            _encryptedSide_BP      = tls_io_callbacks
          , _availableData_BP      = avail_data_ioref
          , _tlsChannel_BP         = tls_channel_ioref
          , _dataCame_BP           = data_came_mvar
          , _handshakeCompleted_BP = handshake_completed_mvar
          , _writeLock_BP          = write_lock_mvar
          , _protocolSelector_BP   = protocolSelectorToC protocol_selector
          , _selectedProtocol_BP   = selected_protocol_mvar
          , _problem_BP            = problem_mvar
          , _active_BP             = active_mvar
          }

        tls_pull_data_action = tls_io_callbacks ^. bestEffortPullAction_IOC

        destructor =
            -- withMVar dontMultiThreadBotan . const $
               iocba_delete_tls_server_channel

    -- botan_pad_stable_ref <- newStablePtr new_botan_pad

    tls_channel_ptr <- withForeignPtr fctx $ \ x -> iocba_new_tls_server_channel  x

    tls_channel_fptr <- newForeignPtr destructor tls_channel_ptr

    let

        pump_exc_handler :: IOProblem -> IO (Maybe LB.ByteString)
        pump_exc_handler _ = do
            _ <- tryPutMVar problem_mvar ()
            -- Wake-up any readers...
            _ <- tryPutMVar data_came_mvar ()
            return Nothing

        -- Feeds encrypted data to Botan
        pump :: IO ()
        pump = do
            maybe_new_data <- E.catch
                (Just <$> tls_pull_data_action True)
                pump_exc_handler
            case maybe_new_data of
                Just new_data
                  | len_new_data <- LB.length new_data, len_new_data > 0 -> do
                    can_continue <- withMVar write_lock_mvar $ \_ -> do
                        maybe_problem <- tryReadMVar problem_mvar
                        case maybe_problem of
                            Nothing -> do
                                maybe_cont_data <- do
                                  let
                                    cleartext_reserve_length :: Int
                                    cleartext_reserve_length = floor $
                                      ((fromIntegral len_new_data * 1.2) :: Double) +
                                      2048.0
                                  allocaBytes cleartext_reserve_length $ \ p_clr_space ->
                                    allocaBytes cleartext_reserve_length $ \ p_enc_to_send ->
                                       alloca $ \ p_enc_to_send_length ->
                                         alloca $ \ p_clr_length -> do
                                                poke p_enc_to_send_length
                                                    $ fromIntegral cleartext_reserve_length
                                                poke p_clr_length $ fromIntegral cleartext_reserve_length
                                                Un.unsafeUseAsCStringLen (LB.toStrict new_data) $ \ (enc_pch, enc_len) ->
                                                    withMVar dontMultiThreadBotan . const $ do
                                                        engine_result <- iocba_receive_data
                                                            tls_channel_ptr
                                                            enc_pch
                                                            (fromIntegral enc_len)
                                                            p_enc_to_send
                                                            p_enc_to_send_length
                                                            p_clr_space
                                                            p_clr_length

                                                        if engine_result < 0
                                                          then do
                                                            _ <- tryPutMVar problem_mvar ()
                                                            -- Just awake any variables
                                                            _ <- tryPutMVar data_came_mvar ()
                                                            return Nothing
                                                          else do
                                                            enc_to_send_length <- peek p_enc_to_send_length
                                                            clr_length <- peek p_clr_length
                                                            to_send <- B.packCStringLen (p_enc_to_send, fromIntegral enc_to_send_length)
                                                            to_return <- B.packCStringLen (p_clr_space, fromIntegral clr_length)
                                                            return $ Just  (to_send, to_return)

                                case maybe_cont_data of
                                    Just (send_to_peer, just_unencrypted) -> do
                                        unless (B.length send_to_peer == 0) .
                                            (tls_io_callbacks ^. pushAction_IOC) .
                                            LB.fromStrict $
                                            send_to_peer
                                        unless (B.length just_unencrypted == 0 ) .
                                            atomicModifyIORef' avail_data_ioref $ \ bu ->
                                              (
                                                bu `seq` (bu `mappend` Bu.byteString just_unencrypted),
                                                ()
                                              )
                                        return True

                                    Nothing -> return False
                            Just _ -> do
                                return False
                    if can_continue
                      then do
                        pump
                      else
                        return ()
                  | otherwise -> do
                    -- This is actually an error
                    pump

                Nothing -> do
                    -- On exceptions, finish this thread
                    return ()

    writeIORef tls_channel_ioref tls_channel_fptr

    result <- newIORef new_botan_pad

    _ <- mkWeakIORef result $ do
        closeBotan new_botan_pad
        -- freeStablePtr botan_pad_stable_ref

    -- Create the pump thread
    _ <- forkIO pump

    return $ BotanSession result


closeBotan :: BotanPad -> IO ()
closeBotan botan_pad =
  do
    tls_channel_fptr <- readIORef (botan_pad ^. tlsChannel_BP)
    withForeignPtr tls_channel_fptr $ \ tls_channel_ptr -> do
        maybe_gotit <- tryTakeMVar (botan_pad ^. active_BP)
        case maybe_gotit of
            Just _ -> do
                -- Let's forbid libbotan for sending more output
                _ <- tryPutMVar (botan_pad ^. problem_BP) ()
                -- Cleanly close tls, if nobody else is writing there
                withMVar (botan_pad ^. writeLock_BP) $ \ _ -> do
                    withMVar dontMultiThreadBotan . const $
                        iocba_close tls_channel_ptr
                    _ <- tryPutMVar (botan_pad ^. problem_BP) ()
                    _ <- tryPutMVar (botan_pad ^. dataCame_BP) ()
                    return ()
                -- Close the cypher-text transport
                (botan_pad ^. encryptedSide_BP . closeAction_IOC)
                -- Ensure that no calls are made to any of the IO callbacks after the
                -- stable pointer is fred

                return ()

            Nothing ->
                -- Thing already closed, don't do it again
                return ()


instance IOChannels BotanSession where

    handshake _botan_session@(BotanSession botan_ioref) = do

        let
            -- Capture the IORef to avoid early finalization
            push_action :: PushAction
            push_action bs = do
                botan_pad <- readIORef botan_ioref
                botanPushData botan_pad bs

            best_effort_pull_action :: BestEffortPullAction
            best_effort_pull_action x = do
                botan_pad <- readIORef botan_ioref
                pullAvailableData botan_pad x

        pull_action_wrapping <- newPullActionWrapping best_effort_pull_action

        botan_pad' <- readIORef botan_ioref
        let
            pull_action :: PullAction
            pull_action = pullFromWrapping' pull_action_wrapping

            best_effort_pull_action' = bestEffortPullFromWrapping pull_action_wrapping

            close_action :: CloseAction
            close_action = closeBotan botan_pad'

            -- handshake_completed_mvar = botan_pad' ^. handshakeCompleted_BP

        -- We needed to wait for a hand-shake
        -- readMVar handshake_completed_mvar

        return $ IOCallbacks {
            _pushAction_IOC = push_action
          , _pullAction_IOC = pull_action
          , _bestEffortPullAction_IOC = best_effort_pull_action'
          , _closeAction_IOC = close_action
            }


instance TLSContext BotanTLSContext BotanSession where
    newTLSContextFromMemory = newBotanTLSContextFromMemory
    newTLSContextFromCertFileNames = newBotanTLSContext
    unencryptTLSServerIO = unencryptChannelData
    getSelectedProtocol (BotanSession pad_ioref) = do
        botan_pad <- readIORef pad_ioref
        a <- readMVar (botan_pad ^. selectedProtocol_BP)
        return ( swap <$> a)


botanTLS :: Proxy BotanTLSContext
botanTLS = Proxy
