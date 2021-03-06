// SPDX-License-Identifier: MIT

pragma solidity >=0.7.0 <0.9.0;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";

// File: contracts/DorisNFT.sol


contract tokenFactory is Ownable {
    address public doris;
    address public platform;
    address public addr;

    constructor(address _platform) {
        doris = msg.sender;
        platform = _platform;
    }

    modifier onlyDoris {
        require(msg.sender==doris, "Unauthorised");
        _;
    }

    function newLine(address _artist, address[] memory _agents, uint256[] memory _agentsfees, uint256 _artistfees, uint256 _dorisfees, string memory _name, string memory _symbol, uint256 _maxSupply, address _link, address _oracle) public payable onlyDoris {
        new DorisNFT(platform, doris, _artist, _link, _oracle, _agents, _agentsfees, _artistfees, _dorisfees, _name, _symbol);
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


    string public uriPrefix = "";
    string public uriSuffix = ".json";
    string public hiddenMetadataUri;
    //string public symbol;
    //string public name;
    uint256 public cost;
    uint256 public maxSupply;
    address public factory;
    address public platform;
    address public doris;
    address public artist;
    address[] public agents;
    uint256 public artistfees;
    uint256 public dorisfees;
    bool public paused = true;
    bytes32 public requestId;
    weatherNFT[] public weather_nfts;
    

    //token structure
    struct weatherNFT {
        string name;
        string precipitationType;
        uint256 timestamp;
        uint24 precipitationPast12Hours;
        uint24 precipitationPast24Hours;
        uint24 precipitationPastHour;
        uint24 presssure;
        uint16 temprature;
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
    mapping(address => uint256) public agentsfees;
    mapping(uint256 => address) public tokenToOwner;
    mapping(bytes32 => weatherNFT) public requestIdToToken;




     /* ========== CONSTRUCTOR ========== */

    /**
    * @param _link the LINK token address.
    * @param _oracle the Operator.sol contract address.
    */
    constructor(
        address _platform,
        address _doris,
        address _artist,
        address _link, 
        address _oracle,
        address[] memory _agents, 
        uint256[] memory _agentsfees,  
        uint256 _dorisfees,
        uint256 _artistfees, 
        string memory _name, 
        string memory _symbol
        ) ERC721(_name,_symbol) payable {
        
        setChainlinkToken(_link);
        setChainlinkOracle(_oracle);

        require(_agents.length == _agentsfees.length, "Mismatch in agents fees");
        
        uint256 totalfee = 0;
        agents = _agents;

        for (uint256 i = 0; i < _agents.length; i++) {
        agents[i] = _agents[i];
        agentsfees[agents[i]] = _agentsfees[i];
        totalfee += _agentsfees[i];
        }
        require((_artistfees + _dorisfees + totalfee)<=100, "Fees > 100%");
        factory = msg.sender;
        doris = _doris;
        //platform = _platform;
        artist = _artist;
        dorisfees = _dorisfees;
        artistfees = _artistfees;
        //symbol = _symbol;
        //name = _name;
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
        string calldata _units
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

        requestId = sendChainlinkRequest(request, _fee);

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
    }

    function createToken(
        string memory _name,
        bytes32 _jobId,
        uint256 _fee,
        string calldata _lat,
        string calldata _lon,
        string calldata _units
        ) public {

        string[5] memory precipitationTypes = ["No precipitation", "Rain", "Snow", "Ice", "Mixed"];

        requestLocationCurrentConditions( _jobId,_fee,_lat,_lon,_units);


        string memory name = _name;

        uint256 timestamp = requestIdCurrentConditionsResult[requestId].timestamp;

        uint24 PP12Hrs = requestIdCurrentConditionsResult[requestId].precipitationPast12Hours;

        uint24 PP24Hrs = requestIdCurrentConditionsResult[requestId].precipitationPast24Hours;

        uint24 PPHr = requestIdCurrentConditionsResult[requestId].precipitationPastHour;

        uint24 pressure = requestIdCurrentConditionsResult[requestId].pressure;

        uint16 temperature = requestIdCurrentConditionsResult[requestId].temperature;

        uint16 windDD = requestIdCurrentConditionsResult[requestId].windDirectionDegrees;

        uint16 windSpeed = requestIdCurrentConditionsResult[requestId].windSpeed;

        string memory ppType = precipitationTypes[requestIdCurrentConditionsResult[requestId].precipitationType];

        uint8 rH = requestIdCurrentConditionsResult[requestId].relativeHumidity;

        uint8 uvI = requestIdCurrentConditionsResult[requestId].uvIndex;

        weather_nfts.push(
            weatherNFT(name, ppType, timestamp, PP12Hrs, PP24Hrs, PPHr, pressure, temperature, windDD, windSpeed, rH, uvI)
        );

    
    }

      /* ========== OTHER FUNCTIONS ========== */

    function getOracleAddress() external view returns (address) {
        return chainlinkOracleAddress();
    }

    function setOracle(address _oracle) external {
        setChainlinkOracle(_oracle);
    }

    function withdrawLink() public onlyPlatform {
        LinkTokenInterface linkToken = LinkTokenInterface(chainlinkTokenAddress());
        require(linkToken.transfer(msg.sender, linkToken.balanceOf(address(this))), "Unable to withdraw funds");
    }

    function setMaxSupply(uint256 _maxSupply) public onlyDoris {
        maxSupply = _maxSupply == 0 ? 2**256-1 : _maxSupply;
    }

  

    function togglePause() public onlyPlatform {
        paused = !paused;
    }

    function totalSupply() public view returns (uint256) {
        return tokenIds.current();
    }

    function mint(address to) public payable onlyPlatform unpaused {
        tokenIds.increment();
        require(tokenIds.current()<maxSupply, "Max supply reached");
        uint256 tokenId = tokenIds.current();
        _safeMint(to, tokenId);
        _handlepaymentnew(msg.value);
    }

    function mintbulk(uint256 qty, address to) public payable onlyPlatform unpaused {
        for (uint256 i = 0; i < qty; i++) {
            tokenIds.increment();
            require(tokenIds.current()< maxSupply, "Max supply reached");
            uint256 tokenId = tokenIds.current();
            _safeMint(to, tokenId);
        }
        _handlepaymentnew(msg.value);

    }

    function _handlepaymentnew(uint256 payment) internal {
        for (uint256 i = 0; i < agents.length; i++) {
            (bool agf, ) = payable(agents[i]).call{value: agentsfees[agents[i]]*payment/100}("");
            require(agf, "Agent fee error");
        }
        (bool df, ) = payable(doris).call{value: dorisfees*payment/100}("");
        require(df, "Doris fee error");
        (bool af, ) = payable(artist).call{value: artistfees*payment/100}("");
        require(af, "Artist fee error");
        (bool ap, ) = payable(artist).call{value: address(this).balance}("");
        require(ap, "Artist payment error");
    }

    function _handlepaymentold(address from, uint256 payment) internal {
        for (uint256 i = 0; i < agents.length; i++) {
            (bool agf, ) = payable(agents[i]).call{value: agentsfees[agents[i]]*payment/100}("");
            require(agf, "Agent fee error");
        }
        (bool df, ) = payable(doris).call{value: dorisfees*payment/100}("");
        require(df, "Doris fee error");
        (bool af, ) = payable(artist).call{value: artistfees*payment/100}("");
        require(af, "Artist fee error");
        (bool ap, ) = payable(from).call{value: address(this).balance}("");
        require(ap, "Seller payment error");
    }

    function tokenURI(uint256 _tokenId)
        public
        view
        virtual
        override
        returns (string memory)
    {
        require(
        _exists(_tokenId),
        "ERC721Metadata: URI query for nonexistent token"
        );

    string memory currentBaseURI = _baseURI();
    return bytes(currentBaseURI).length > 0
        ? string(abi.encodePacked(currentBaseURI, _tokenId.toString(), uriSuffix))
        : "";
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
