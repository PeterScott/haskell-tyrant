import Control.Monad
import Control.Arrow ((&&&))
import Network.Socket hiding (send, sendTo, recv, recvFrom)
import Network.Socket.ByteString
import qualified Data.ByteString.Lazy.Char8 as LS
import qualified Data.ByteString.Char8 as S
import Data.Binary
import qualified Data.Binary.Get as BG
import Data.Int
import Data.Binary.Put (runPut, putLazyByteString)
import Data.Word (Word8, Word16, Word32)
import qualified Constants as C

toStrict = S.concat . LS.toChunks
toLazy s = LS.fromChunks [s]

length32 :: LS.ByteString -> Int32
length32 s = fromIntegral $ LS.length s

len32 :: [a] -> Int32
len32 lst = fromIntegral $ length lst

runPS = toStrict . runPut

makeVsiz :: LS.ByteString -> Put
makeVsiz key = do
    put C.magic
    put C.vsiz
    let klen = length32 key
    put klen

makeOut :: LS.ByteString -> Put
makeOut key = do
    put C.magic >> put C.out
    let klen = length32 key
    put klen
    putLazyByteString key

makePuts :: Word8 -> LS.ByteString -> LS.ByteString -> Put
makePuts code key value = do
    put C.magic
    put code
    let klen = length32 key
    let vlen = length32 value
    put klen >> put vlen
    putLazyByteString key >> putLazyByteString value

makePut :: LS.ByteString -> LS.ByteString -> Put
makePut key value = makePuts C.put key value

makePutKeep :: LS.ByteString -> LS.ByteString -> Put
makePutKeep key value = makePuts C.putkeep key value

makePutCat :: LS.ByteString -> LS.ByteString -> Put
makePutCat key value = makePuts C.putcat key value

makeGet :: LS.ByteString -> Put
makeGet key = do
    put C.magic
    put C.get
    put (length32 key)

getRetCode = do
    rawCode <- BG.getWord8
    let ret = (fromEnum rawCode)::Int
    return ret

openConnect :: HostName -> ServiceName -> IO Socket
openConnect hostname port = do
    addrinfos <- getAddrInfo Nothing (Just hostname) (Just port)
    let addr = head addrinfos
    sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
    setSocketOption sock NoDelay 1
    connect sock (addrAddress addr)
    return sock

putValue :: Socket -> LS.ByteString -> LS.ByteString -> IO Bool
putValue sock key value = do
    let msg = runPS $ makePut key value
    res <- send sock msg
    sockSuccess sock

putIntValue :: (Num a, Integral a) => Socket -> LS.ByteString -> a -> IO Bool
putIntValue sock key value = do
    let vi32 = (fromIntegral value)::Int32
    let vbs = runPut $ put vi32
    putValue sock key vbs

getValue :: Socket -> LS.ByteString -> IO (Maybe LS.ByteString)
getValue sock key = do
    let metaData = runPut $ makeGet key
    let msg = toStrict $ LS.concat [metaData, key]
    res <- send sock msg
    fetch <- recv sock 5
    let (code, valLen) = BG.runGet getGet $ toLazy fetch
    case code of
        0 -> do
            rawValue <- recv sock valLen
            return $ Just (toLazy rawValue)
        _ -> return Nothing

getDouble sock key = do 
    adddouble sock key 0.0

getInt sock key = do
    addInt sock key 0

putKeep :: Socket -> LS.ByteString -> LS.ByteString -> IO Bool
putKeep sock key value = do
    let msg = runPS $ makePutKeep key value
    res <- send sock msg
    sockSuccess sock

putCat :: Socket -> LS.ByteString -> LS.ByteString -> IO Bool
putCat sock key value = do
    let msg = runPS $ makePutCat key value
    sent <- send sock msg
    sockSuccess sock

sockSuccess :: Socket -> IO Bool
sockSuccess sock = do
    rawRetCode <- recv sock 1
    let retCode = BG.runGet getRetCode (toLazy rawRetCode)
    return $ retCode == 0

out :: Socket -> LS.ByteString -> IO Bool
out sock key = do
    let msg = runPS $ makeOut key
    sent <- send sock msg
    sockSuccess sock

vsiz :: Socket -> LS.ByteString -> IO (Maybe Int)
vsiz sock key = do
    let metaData = runPut $ makeVsiz key
    let msg = toStrict $ LS.concat [metaData, key]
    res <- send sock msg
    fetch <- recv sock 5
    let (code, valLen) = BG.runGet getGet $ toLazy fetch
    case code of
        0 -> return $ Just valLen
        _ -> return Nothing

mget sock keys = do
    let msg = toStrict . runPut $ makeMGet keys
    res <- send sock msg
    hdr <- recv sock 5
    let (code, rnum) = BG.runGet getGet $ toLazy hdr
    pairs <- getManyMGet sock rnum []
    return pairs

makeMGet keys = do
    put C.magic
    put C.mget
    let nkeys = len32 keys
    put nkeys
    let z = [(length32 x, x) | x <- keys]
    mapM_ (\(x, y) -> put x >> putLazyByteString y) z

getManyMGet _ 0 acc = return acc
getManyMGet sock rnum acc = do
    hdr <- recv sock 8
    let (ksize, vsize) = BG.runGet getMGetHeader $ toLazy hdr
    body <- recv sock $ ksize + vsize
    let el = BG.runGet (getOneMGet ksize vsize) $ toLazy body
    getManyMGet sock (rnum-1) (el:acc)

getMGetHeader = do
    rawksize <- BG.getWord32be
    let ksize = (fromEnum rawksize)::Int
    rawvsize <- BG.getWord32be
    let vsize = (fromEnum rawvsize)::Int
    return (ksize, vsize)
    
getOneMGet ksize vsize = do
    k <- BG.getLazyByteString $ toEnum ksize
    v <- BG.getLazyByteString $ toEnum vsize
    return (k, v)

getGet = do
    rawcode <- BG.getWord8
    let code = (fromEnum rawcode)::Int
    --ln is "on success: A 32-bit integer standing for the length of the value"
    ln <- BG.getWord32be
    let len = (fromEnum ln)::Int
    return (code, len)

vanish sock = do
    let msg = toStrict . runPut $ (put C.magic >> put C.vanish)
    sent <- send sock msg
    sockSuccess sock

sync sock = do
    let msg = toStrict . runPut $ (put C.magic >> put C.sync)
    sent <- send sock msg
    sockSuccess sock

copy sock path = do
    let pathLen = length32 path
    let msg = toStrict . runPut $ (put C.magic >> put C.copy >> put pathLen >> putLazyByteString path)
    sent <- send sock msg
    sockSuccess sock

addInt sock key x = do
    let wx = (fromIntegral x)::Int32
    let klen = length32 key
    let msg = toStrict . runPut $ (put C.magic >> put C.addint >> put klen >> put wx >> putLazyByteString key)
    sent <- send sock msg
    fetch <- recv sock 5
    let (code, thesum) = BG.runGet getGet $ toLazy fetch
    case code of
        0 -> return $ Just thesum
        _ -> return Nothing

parseSize = do
    rawcode <- BG.getWord8
    let code = (fromEnum rawcode)::Int
    rawSize <- BG.getWord64be
    let size = (fromEnum rawSize)::Int
    return (code, size)

sizeOrRNum sock cmdId = do
    let msg = toStrict . runPut $ (put C.magic >> put cmdId)
    sent <- send sock msg
    fetch <- recv sock 9
    let (code, siz) = BG.runGet parseSize $ toLazy fetch
    case code of
        0 -> return $ Just siz
        _ -> return Nothing

size sock = sizeOrRNum sock C.size
rnum sock = sizeOrRNum sock C.rnum

stat sock = do
    sent <- send sock $ toStrict . runPut $ (put C.magic >> put C.stat)
    resHeader <- recv sock 5
    let (code, ssiz) = BG.runGet getGet $ toLazy resHeader
    case code of
        0 -> do
            rawStat <- recv sock ssiz
            let statPairs = map (S.split '\t') $ S.lines rawStat
            return $ Just statPairs
        _ -> return Nothing

restore sock path ts = do
    let pl = length32 path
    let ts64 = (fromIntegral ts)::Int64
    let restorePut = (put C.magic >> put C.restore >> put pl >> put ts64 >> putLazyByteString path)
    sent <- send sock $ runPS restorePut
    sockSuccess sock

setmst sock host port = do
    let hl = length32 host
    let port32 = (fromIntegral port)::Int32
    let setmstPut = (put C.magic >> put C.setmst >> put hl >> put port32 >> putLazyByteString host)
    sent <- send sock $ runPS setmstPut
    sockSuccess sock

integFract :: (RealFrac b) => b -> (Int64, Int64)
integFract num = (integ, fract)
    where integ = (truncate num)
          fract = truncate . (* 1e12) . snd $ properFraction num

parseAddDoubleReponse = do
    integ <- get :: Get Int64
    fract <- get :: Get Int64
    return (integ, fract)

doublePut key integ fract = do
    put C.magic >> put C.adddouble
    let klen = length32 key
    put klen >> put integ >> put fract
    putLazyByteString key

adddouble sock key num = do
    let (integ, fract) = integFract num
    let msg = runPS $ doublePut key integ fract
    sent <- send sock msg
    rawCode <- recv sock 1
    let code = BG.runGet getRetCode $ toLazy rawCode
    case code of
        0 -> do
            fetch <- recv sock 16
            return $ Just $ BG.runGet parseAddDoubleReponse $ toLazy fetch
        _ -> return Nothing

main = do
    let k = LS.pack "hab"
    let v = LS.pack "blab"
    s <- openConnect "localhost" "1978"
    b <- putValue s k v
    bump <- getValue s k
    print bump
    let k2 = LS.pack "test"
    let v2 = LS.pack "gabi"
    pkd <- putKeep s k v2
    redid <- getValue s k
    print redid
    --Now slap another "blab" on the end
    catd <- putCat s k v
    print catd
    --show
    hey <- getValue s k
    print hey
    --add another pair
    yodo <- putValue s k2 v2
    print yodo
    zoop <- getValue s k2
    print zoop
    --use out to kill the (k2, v2) pair
    killed <- out s k2
    print killed    -- should be True
    -- Try to fetch value which we've just killed, should be Nothing
    zoop2 <- getValue s k2
    print zoop2
    valSize <- vsiz s k
    print valSize
    let keys = [LS.pack "yex", LS.pack "one", k]
    pairs <- mget s keys
    let outPath = LS.pack "/home/travis/hogo.tch"
    copyConfirm <- copy s outPath
    print copyConfirm
    --areTheyGone <- vanish s
    let k3 = LS.pack "dude"
    let v3 = runPut $ put (0::Int32)
    pd <- putValue s k3 v3
    zap <- getValue s k3
    jungle <- addInt s k3 (20::Int)
    sz <- size s
    numrecs <- rnum s
    stats <- stat s
    let k4 = LS.pack "xxx"
    let v4 = 9
    pti <- putIntValue s k4 v4
    let k5 = LS.pack "dubval"
    let v5 = LS.pack "500"
    randy <- putValue s k5 v5
    --let v5 = 5.5
    dubx <- adddouble s k5 5.5
    let k6 = LS.pack "blah"
    dud <- adddouble s k6 10.005
    sally <- getValue s k6
    let k7 = LS.pack "k7"
    swoop <- addInt s k7 1
    hump <- getInt s k7
    let k8 = LS.pack "argo"
    jump <- getDouble s k8
    let k9 = LS.pack "blogo"
    i0 <- getInt s k9
    inext <- addInt s k9 1
    sClose s
    return inext
