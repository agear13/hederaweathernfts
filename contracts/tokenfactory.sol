// SPDX-License-Identifier: MIT

pragma solidity >=0.7.0 <0.9.0;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import "base64-sol/base64.sol";

// File: contracts/DorisNFT.sol


contract tokenFactory is Ownable {
    address public doris;
    address public platform;

    constructor(address _platform) {
        doris = msg.sender;
        platform = _platform;
    }

    modifier onlyDoris {
        require(msg.sender==doris, "Unauthorised");
        _;
    }

    function newLine(address _platform, address _doris, address _link, address _oracle, string memory _name, string memory _symbol) public payable onlyDoris {
        new DorisNFT(_platform,_doris, _link, _oracle, _name, _symbol);
    }


    function changeDoris (address _newdoris) external onlyDoris {
        doris = _newdoris;
    }

}


contract DorisNFT is ERC721URIStorage, Ownable, ChainlinkClient {
    using Strings for uint256;
    using Counters for Counters.Counter;
    using Chainlink for Chainlink.Request;

    Counters.Counter private tokenIds;

    uint256 public cost;
    uint256 public maxSupply;
    address public factory;
    address public platform;
    address public doris;
    address public artist;
    uint8 public artistfees;
    uint8 public dorisfees;
    uint256 public fee;
    bytes32 public jobId;
    bool public paused = true;
    bytes32[] requestIds;
    weatherNFT[] public weather_nfts;

    string[5] imageURIs;
    string imageURI;
    string[5] precipitationTypes = ["No precipitation", "Rain", "Snow", "Ice", "Mixed"];

    

    //token structure
    struct weatherNFT {
        string location;
        string precipitationType;
        uint256 timestamp;
        uint24 precipitationPast24Hours;
        uint24 pressure;
        uint16 temperature;
        uint16 windDirectionDegrees;
        uint16 windSpeed;
        uint8 relativeHumidity;
        uint8 uvIndex;
    }
    
    /* ========== CONSUMER STATE VARIABLES ========== */

    struct RequestParams {
        uint256 locationKey;
        string endpoint;
        string lat;
        string lon;
        string units;
    }

     struct LocationResult {
        uint256 locationKey;
        string name;
        bytes2 countryCode;
    }
   
    struct CurrentConditionsResult {
        uint256 timestamp;
        uint24 precipitationPast12Hours;
        uint24 precipitationPast24Hours;
        uint24 precipitationPastHour;
        uint24 pressure;
        uint16 temperature;
        uint16 windDirectionDegrees;
        uint16 windSpeed;
        uint8 precipitationType;
        uint8 relativeHumidity;
        uint8 uvIndex;
        uint8 weatherIcon;
    }

    // Maps
    mapping(bytes32 => CurrentConditionsResult) public requestIdCurrentConditionsResult;
    mapping(bytes32 => LocationResult) public requestIdLocationResult;
    mapping(bytes32 => RequestParams) public requestIdRequestParams;
    mapping(uint256 => weatherNFT) public tokenIdToToken;




     /* ========== CONSTRUCTOR ========== */

    /**
    * @param _link the LINK token address.
    * @param _oracle the Operator.sol contract address.
    */
    constructor(
        address _platform,
        address _doris,
        address _link, 
        address _oracle,
        string memory _name, 
        string memory _symbol
        ) ERC721(_name,_symbol) payable {
        
        setChainlinkToken(_link);
        setChainlinkOracle(_oracle);
        
        factory = msg.sender;
        doris = _doris;
        platform = _platform;
    }

    receive() external payable {
        revert("Don't send funds here");
    }

    modifier unpaused {
        require(!paused, "NFT paused");
        _;
    }
    modifier onlyPlatform {
        require(msg.sender == platform || msg.sender == doris, "Not platform");
        _;
    }
    modifier onlyDoris {
        require(msg.sender==doris, "Unauthorised");
        _;
    }


     /**    API consumer
     @dev
     * precipitationType (uint8)
    * --------------------------
    * Value    Type
    * --------------------------
    * 0        No precipitation
    * 1        Rain
    * 2        Snow
    * 3        Ice
    * 4        Mixed

    * Current weather conditions units per system
    * ---------------------------------------------------
    * Condition                    metric      imperial
    * ---------------------------------------------------
    * precipitationPast12Hours     mm          in
    * precipitationPast24Hours     mm          in
    * precipitationPastHour        mm          in
    * pressure                     mb          inHg
    * temperature                  C           F
    * windSpeed                    km/h        mi/h
    */

    
    /**
     * @notice Returns the current weather conditions of a location for the given coordinates.
      * @dev Uses @chainlink/contracts 0.4.0.
     * @param _jobId the jobID.
     * @param _fee the LINK amount in Juels (i.e. 10^18 aka 1 LINK).
     * @param _lat the latitude (WGS84 standard, from -90 to 90).
     * @param _lon the longitude (WGS84 standard, from -180 to 180).
     * @param _units the measurement system ("metric" or "imperial").
     */

    

    function requestLocationCurrentConditions(
        bytes32 _jobId,
        uint256 _fee,
        string calldata _lat,
        string calldata _lon,
        string memory _units
    ) public {
            LinkTokenInterface linkToken = LinkTokenInterface(chainlinkTokenAddress());
        require( linkToken.balanceOf(address(this)) >= _fee,
         "Not enough LINK- fund contract!"
         );
        
        Chainlink.Request memory request = buildChainlinkRequest(
            _jobId,
            address(this),
            this.fulfillLocationCurrentConditions.selector
        );

        //request.add("endpoint", "location-current-conditions"); // NB: not required if it has been hardcoded in the jobId
        request.add("lat", _lat);
        request.add("lon", _lon);
        request.add("units", _units);

        bytes32 requestId = sendChainlinkRequest(request, _fee);

        // Below this line is just an example of usage
        storeRequestParams(requestId, 0, "location-current-conditions", _lat, _lon, _units);
    }


        /*======FULFILMENT FUNCTIION====== **/
    /**
     * @notice Consumes the data returned by the node job on a particular request.
     * @dev Only when `_locationFound` is true, both `_locationFound` and `_currentConditionsResult` will contain
     * meaningful data (as bytes). 
     * @param _requestId the request ID for fulfillment.
     * @param _locationFound true if a location was found for the given coordinates, otherwise false.
     * @param _locationResult the location information (encoded as LocationResult).
     * @param _currentConditionsResult the current weather conditions (encoded as CurrentConditionsResult).
     */
    function fulfillLocationCurrentConditions(
        bytes32 _requestId,
        bool _locationFound,
        bytes memory _locationResult,
        bytes memory _currentConditionsResult
    ) public recordChainlinkFulfillment(_requestId) {
        if (_locationFound) {
            storeLocationResult(_requestId, _locationResult);
            storeCurrentConditionsResult(_requestId, _currentConditionsResult);
        }
    }

        /*======PRIVATE FUNCTIONS======**/
     function storeRequestParams(
        bytes32 _requestId,
        uint256 _locationKey,
        string memory _endpoint,
        string memory _lat,
        string memory _lon,
        string memory _units
    ) private {
        RequestParams memory requestParams;
        requestParams.locationKey = _locationKey;
        requestParams.endpoint = _endpoint;
        requestParams.lat = _lat;
        requestParams.lon = _lon;
        requestParams.units = _units;
        requestIdRequestParams[_requestId] = requestParams;
    }

     function storeLocationResult(bytes32 _requestId, bytes memory _locationResult) private {
        LocationResult memory result = abi.decode(_locationResult, (LocationResult));
        requestIdLocationResult[_requestId] = result;
    }

    function storeCurrentConditionsResult(bytes32 _requestId, bytes memory _currentConditionsResult) private {
        CurrentConditionsResult memory result = abi.decode(_currentConditionsResult, (CurrentConditionsResult));
        requestIdCurrentConditionsResult[_requestId] = result;
        requestIds.push(_requestId);
    }

    function createToken(
        string memory _location,
        string calldata _lat,
        string calldata _lon
        ) public onlyDoris {

        require(tokenIds.current()<maxSupply, "Max supply reached");

        requestLocationCurrentConditions(jobId,fee,_lat,_lon,"metric");

        weatherNFT memory newToken;
       
        newToken.location = _location;

        newToken.timestamp = requestIdCurrentConditionsResult[requestIds[requestIds.length]].timestamp;

        newToken.precipitationPast24Hours = requestIdCurrentConditionsResult[requestIds[requestIds.length]].precipitationPast24Hours;

        newToken.pressure = requestIdCurrentConditionsResult[requestIds[requestIds.length]].pressure;

        newToken.temperature = requestIdCurrentConditionsResult[requestIds[requestIds.length]].temperature;

        newToken.windDirectionDegrees = requestIdCurrentConditionsResult[requestIds[requestIds.length]].windDirectionDegrees;

        newToken.windSpeed = requestIdCurrentConditionsResult[requestIds[requestIds.length]].windSpeed;

        newToken.precipitationType = precipitationTypes[requestIdCurrentConditionsResult[requestIds[requestIds.length]].precipitationType];

        newToken.relativeHumidity = requestIdCurrentConditionsResult[requestIds[requestIds.length]].relativeHumidity;

        newToken.uvIndex = requestIdCurrentConditionsResult[requestIds[requestIds.length]].uvIndex;

        weather_nfts.push(newToken);

        tokenIds.increment();
        _setTokenURI(tokenIds.current(), formatTokenURI(newToken));
        _safeMint(msg.sender, tokenIds.current());
        tokenIdToToken[tokenIds.current()] = weather_nfts[tokenIds.current() - 1];
    }

      /* ========== OTHER FUNCTIONS ========== */

    function getOracleAddress() external view returns (address) {
        return chainlinkOracleAddress();
    }

    function setOracle(address _oracle) external {
        setChainlinkOracle(_oracle);
    }

    function withdrawLink() public onlyDoris {
        LinkTokenInterface linkToken = LinkTokenInterface(chainlinkTokenAddress());
        require(linkToken.transfer(msg.sender, linkToken.balanceOf(address(this))), "Unable to withdraw funds");
    }

    function setMaxSupply(uint256 _maxSupply) external onlyPlatform {
        maxSupply = _maxSupply == 0 ? 2**256-1 : _maxSupply;
    }

    function setJobidAndFee(bytes32 _jobId, uint256 _fee) external onlyPlatform {
        jobId = _jobId;
        fee = _fee;
    }

    function setTokenPrice(uint256 _cost) external onlyDoris {
        cost = _cost;
    }

    function setArtist(address _artist) external onlyPlatform {
        artist = _artist;
    }

    function setFees(uint8 _dorisfees, uint8 _artistfees) external onlyDoris {
        require((_artistfees + _dorisfees)<=100, "Fees > 100%");
        dorisfees = _dorisfees;
        artistfees = _artistfees;
    }

    

    function setImageURIs(string[4] memory _imageURIs) external onlyDoris {
        imageURIs = [_imageURIs[0], _imageURIs[1], _imageURIs[2], _imageURIs[2], _imageURIs[3]];
        imageURI = imageURIs[requestIdCurrentConditionsResult[requestIds[requestIds.length]].precipitationType];
    }
     


    function togglePause() public onlyPlatform {
        paused = !paused;
    }

    function totalSupply() public view returns (uint256) {
        return tokenIds.current();
    }

    function mint(address _to, uint256 _tokenId) external payable unpaused {
        require(msg.value >= cost);
        require(_tokenId <= tokenIds.current());
        _transfer(doris, _to, _tokenId);
        _handlepaymentnew(msg.value);
    }

    function _handlepaymentnew(uint256 payment) public {
        (bool df, ) = payable(doris).call{value: dorisfees*payment/100}("");
        require(df, "Doris fee error");
        (bool ap, ) = payable(artist).call{value: address(this).balance}("");
        require(ap, "Artist payment error");
    }

    function _handlepaymentold(address from, uint256 payment) public payable {
        (bool df, ) = payable(doris).call{value: dorisfees*payment/100}("");
        require(df, "Doris fee error");
        (bool af, ) = payable(artist).call{value: artistfees*payment/100}("");
        require(af, "Artist fee error");
        (bool ap, ) = payable(from).call{value: address(this).balance}("");
        require(ap, "Seller payment error");
    }
    
    
    function _base64(weatherNFT memory _newToken) 
    private view returns(string memory) {
        return(Base64.encode(bytes(
                        abi.encodePacked(
                            '{"name": "Weather NFT"',
                            '"description": "A collection of artworks of landscapes/places around the world that respond to physical conditions at the location"' ,
                            '"image":',imageURI,
                            '"attributes": [',
                                '{',
                                    '"condition_type": "Location"',
                                    '"value":', _newToken.location,
                                '}',
                                '{',
                                    '"condition_type": "Precipitation Type"',
                                    '"value":', _newToken.precipitationType,
                                '}',
                                '{',
                                    '"condition_type": "Timestamp"',
                                    '"value":', _newToken.timestamp,
                                '}',
                                '{',
                                    '"condition_type": "Precipitation past 24 hours"',
                                    '"value":', _newToken.precipitationPast24Hours,
                                '}',
                                '{',
                                    '"condition_type": "Pressure"',
                                    '"value":', _newToken.pressure,
                                '}',
                                '{',
                                    '"condition_type": "Temprature"',
                                    '"value":', _newToken.temperature,
                                '}',
                                '{',
                                    '"condition_type": "Wind direction in degrees"',
                                    '"value":', _newToken.windDirectionDegrees,
                                '}',
                                '{',
                                    '"condition_type": "Wind speed"',
                                    '"value":', _newToken.windSpeed,
                                '}',
                                '{',
                                    '"condition_type": "Relative humidity"',
                                    '"value":', _newToken.relativeHumidity,
                                '}',
                                '{',
                                    '"condition_type": "uvIndex"',
                                    '"value":', _newToken.uvIndex,
                                '}',
                            ']'
                        '}'
                            
                        )
                    )));
    }


    function formatTokenURI(
        weatherNFT memory _newToken 
    ) internal returns (string memory) {
        return string(abi.encodePacked(
            "data:application/json;base64,", _base64(_newToken))
        );    
    }        


    function transferTokenFrom(address from, address to, uint256 tokenId) public payable onlyPlatform unpaused {
        transferFrom(from, to, tokenId);
        _handlepaymentold(from,msg.value);
    }


    function approve(address to, uint256 tokenId) public virtual override(ERC721) {
        address owner = ERC721.ownerOf(tokenId);
        require(to != owner, "ERC721: approval to current owner");
        require(msg.sender == owner, "ERC721: approve caller is not owner nor approved for all");
        _approve(to, tokenId);
    }

}
