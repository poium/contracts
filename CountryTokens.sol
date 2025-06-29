// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract CountryTokens is ERC1155, ERC1155Supply, Ownable, Pausable, ReentrancyGuard {
    // Constants
    uint256 public constant BASE_PRICE = 100 * 1e18; // 100 HELLO tokens
    uint256 public constant DEV_FEE_PERCENT = 250; // 2.5% (basis points)
    uint256 public constant MIN_FEE_PERCENT = 50; // 0.5% (basis points)
    uint256 public constant MAX_FEE_PERCENT = 1000; // 10% (basis points)
    uint256 public constant REFERRAL_REWARD_PERCENT = 50; // 0.5% (basis points)
    uint256 public constant HEAD_FEE_PERCENT = 100; // 1% (basis points)
    uint256 public constant MAX_PRICE = 1e30; // Cap to prevent overflow
    uint256 public constant MIN_PRICE = 1e12; // Minimum price
    uint256 public constant MAX_PURCHASE_AMOUNT = 1e18; // Max tokens per transaction
    uint256 public constant MAX_COUNTRIES = 100; // Maximum number of countries
    uint256 public constant MAX_TREASURY_BALANCE = 1e30; // Maximum treasury balance per country
    IERC20 public constant HELLO = IERC20(0x20979ed939BEeB5980215Be85f2B292abeAfBD3E);
    uint256 public constant ONE = 1e18; // fixed-point precision
    uint256 private constant PRICE_RATE = 1000500000000000000; // 1.0005 * 1e18

    // State variables
    address public devWallet;
    address public gameContract;
    address public countryHeadContract; // ERC721 contract for country heads
    uint256 public totalCountries;
    mapping(uint256 => uint256) public countryHelloLocked;
    mapping(uint256 => uint256) public countryTreasuryBalance;
    uint256 public totalHelloLocked;
    mapping(uint256 => string) public countryNames;
    mapping(address => address) public referrers; // Maps user to their referrer
    mapping(address => bool) private _hasReferrer; // Tracks if a user has set a referrer

    // Events
    event TokensBought(
        uint256 indexed countryId,
        address to,
        uint256 amount,
        uint256 helloPaid,
        uint256 dynamicFee,
        uint256 devFee
    );
    event TokensSold(
        uint256 indexed countryId,
        address indexed seller,
        uint256 amount,
        uint256 helloReceived,
        uint256 dynamicFee,
        uint256 devFee
    );
    event TreasuryWithdrawn(uint256 indexed countryId, address to, uint256 amount);
    event TreasuryDeposited(uint256 indexed countryId, address indexed sender, uint256 amount); // New event
    event FundsSent(address indexed recipient, uint256 amount);
    event CountryAdded(uint256 indexed countryId, string name);
    event DevWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event GameContractUpdated(address indexed oldGameContract, address indexed newGameContract);
    event URIUpdated(string newUri);
    event ReferrerSet(address indexed user, address indexed referrer);
    event ReferralRewardAllocated(address indexed referrer, uint256 amount);
    event HeadFeeAllocated(address indexed headOwner, uint256 amount);

    // Struct for country summary
    struct CountrySummary {
        uint256 countryId;
        string name;
        uint256 supply;
        uint256 price;
        uint256 helloLocked;
        uint256 treasuryBalance;
        uint256 dynamicFee;
        uint256 timestamp;
    }

    // Struct for user summary
    struct UserSummary {
        uint256[] balances;
        uint256 timestamp;
    }

    // Constructor
    constructor(string memory uri_) ERC1155(uri_) Ownable(msg.sender) {
        devWallet = msg.sender;
        totalCountries = 0;
    }

    // Getter for devWallet (required for CountryGame compatibility)
  function getDevWallet() external view returns (address) {
    return devWallet;
}

    // NEW: Deposit HELLO to a country's treasury (only by game contract)
    /// @notice Allows the game contract to deposit HELLO into a country's treasury.
    /// @param countryId The ID of the country (1 to totalCountries).
    function depositToTreasury(uint256 countryId, uint256 amount) external nonReentrant {
        require(msg.sender == gameContract, "Only game contract can deposit");
        require(countryId >= 1 && countryId <= totalCountries, "Invalid country ID");
        require(amount > 0, "Deposit amount must be greater than zero");
        require(HELLO.transferFrom(msg.sender, address(this), amount), "HELLO transfer failed");
        uint256 newTreasuryBalance = countryTreasuryBalance[countryId] + amount;
        require(newTreasuryBalance <= MAX_TREASURY_BALANCE, "Treasury balance too high");
        countryTreasuryBalance[countryId] = newTreasuryBalance;
        emit TreasuryDeposited(countryId, msg.sender, amount);
    }

    // Set referrer for a user
    function setReferrer(address referrer) external {
        require(referrer != address(0), "Invalid referrer address");
        require(referrer != msg.sender, "Cannot refer oneself");
        require(!_hasReferrer[msg.sender], "Referrer already set");
        require(referrers[referrer] != msg.sender, "Circular referral not allowed");
        referrers[msg.sender] = referrer;
        _hasReferrer[msg.sender] = true;
        emit ReferrerSet(msg.sender, referrer);
    }

    // Get current price for a country token based on exponential bonding curve (1.0005^supply)
    function getPrice(uint256 countryId) public view returns (uint256) {
        require(countryId >= 1 && countryId <= totalCountries, "Invalid country ID");
        uint256 supply = totalSupply(countryId);
        uint256 factor = _powFixed(PRICE_RATE, supply); // 1.0005 ^ supply (fixed-point)
        uint256 price = (BASE_PRICE * factor) / ONE;
        if (price < MIN_PRICE) return MIN_PRICE;
        if (price > MAX_PRICE) return MAX_PRICE;
        return price;
    }

    // Get dynamic fee percentage based on country's HELLO locked
    function getDynamicFee(uint256 countryId) public view returns (uint256) {
        require(countryId >= 1 && countryId <= totalCountries, "Invalid country ID");
        if (totalHelloLocked == 0) return MIN_FEE_PERCENT;
        uint256 calculatedFee = (countryHelloLocked[countryId] * 10000) / totalHelloLocked;
        if (calculatedFee < MIN_FEE_PERCENT) return MIN_FEE_PERCENT;
        if (calculatedFee > MAX_FEE_PERCENT) return MAX_FEE_PERCENT;
        return calculatedFee;
    }

    // Buy tokens for a country
    /// @return totalCostHELLO  Total HELLO transferred from the buyer (baseCost + all fees).
    function buy(uint256 countryId, uint256 amount, address referrer)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 totalCostHELLO)
    {
        require(countryId >= 1 && countryId <= totalCountries, "Invalid country ID");
        require(amount > 0, "Amount must be greater than zero");
        require(amount <= MAX_PURCHASE_AMOUNT, "Amount exceeds max purchase limit");

        if (!_hasReferrer[msg.sender] && referrer != address(0) && referrer != msg.sender && referrers[referrer] != msg.sender) {
            referrers[msg.sender] = referrer;
            _hasReferrer[msg.sender] = true;
            emit ReferrerSet(msg.sender, referrer);
        }

        uint256 supplyBefore = totalSupply(countryId);
        uint256 geom = _geomSum(PRICE_RATE, supplyBefore, amount); // 1e18 scaled
        uint256 baseCost = (BASE_PRICE * geom) / ONE; // cost before fees

        uint256 dynamicFeePercent = getDynamicFee(countryId);
        uint256 dynamicFee     = (baseCost * dynamicFeePercent) / 10000;
        uint256 devFee         = (baseCost * DEV_FEE_PERCENT) / 10000;
        uint256 referralReward = (baseCost * REFERRAL_REWARD_PERCENT) / 10000;
        uint256 headFee        = (baseCost * HEAD_FEE_PERCENT) / 10000;
        uint256 totalCost = baseCost + dynamicFee + devFee + referralReward + headFee;
        require(HELLO.transferFrom(msg.sender, address(this), totalCost), "HELLO transfer failed");

        uint256 netAmount = baseCost;

        countryHelloLocked[countryId] += netAmount;
        totalHelloLocked += netAmount;

        uint256 newTreasuryBalance = countryTreasuryBalance[countryId] + dynamicFee;
        require(newTreasuryBalance <= MAX_TREASURY_BALANCE, "Treasury balance too high");
        countryTreasuryBalance[countryId] = newTreasuryBalance;

        // Instantly pay dev fee
        if (devFee > 0) {
            require(HELLO.transfer(devWallet, devFee), "HELLO transfer failed");
            emit FundsSent(devWallet, devFee);
        }

        // Instantly pay referral reward (or to devWallet if no referrer)
        if (_hasReferrer[msg.sender] && referralReward > 0 && referrers[msg.sender] != address(0)) {
            address actualReferrer = referrers[msg.sender];
            require(HELLO.transfer(actualReferrer, referralReward), "HELLO transfer failed");
            emit ReferralRewardAllocated(actualReferrer, referralReward);
            emit FundsSent(actualReferrer, referralReward);
        } else if (referralReward > 0) {
            require(HELLO.transfer(devWallet, referralReward), "HELLO transfer failed");
            emit FundsSent(devWallet, referralReward);
        }

        // Instantly pay head fee to current head owner (or devWallet if none)
        if (headFee > 0) {
            address headOwner = _getHeadOwner(countryId);
            if (headOwner == address(0)) headOwner = devWallet;
            require(HELLO.transfer(headOwner, headFee), "HELLO transfer failed");
            emit HeadFeeAllocated(headOwner, headFee);
            emit FundsSent(headOwner, headFee);
        }

        _mint(msg.sender, countryId, amount, "");

        emit TokensBought(countryId, msg.sender, amount, totalCost, dynamicFee, devFee);

        totalCostHELLO = totalCost;
        return totalCostHELLO;
    }

    // Sell tokens for a country
    /// @return helloReceived  Net HELLO the seller receives after all fees.
    function sell(uint256 countryId, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 helloReceived)
    {
        require(countryId >= 1 && countryId <= totalCountries, "Invalid country ID");
        require(amount > 0, "Amount must be greater than zero");
        require(amount <= MAX_PURCHASE_AMOUNT, "Amount exceeds max sell limit");
        require(balanceOf(msg.sender, countryId) >= amount, "Insufficient tokens");

        uint256 supplyBefore = totalSupply(countryId);
        require(supplyBefore >= amount, "supply underflow");
        uint256 startExp = supplyBefore - amount;
        uint256 geom = _geomSum(PRICE_RATE, startExp, amount);
        uint256 totalValue = (BASE_PRICE * geom) / ONE;
        uint256 dynamicFeePercent = getDynamicFee(countryId);
        uint256 dynamicFee = (totalValue * dynamicFeePercent) / 10000;
        uint256 devFee = (totalValue * DEV_FEE_PERCENT) / 10000;
        uint256 referralReward = (totalValue * REFERRAL_REWARD_PERCENT) / 10000;
        uint256 headFee        = (totalValue * HEAD_FEE_PERCENT) / 10000;
        uint256 netAmount = totalValue - dynamicFee - devFee - referralReward - headFee;

        require(countryHelloLocked[countryId] >= totalValue, "Insufficient country HELLO locked");
        require(totalHelloLocked >= totalValue, "Insufficient total HELLO locked");

        // release the entire baseValue that was previously locked
        countryHelloLocked[countryId] -= totalValue;
        totalHelloLocked -= totalValue;

        uint256 newTreasuryBalance = countryTreasuryBalance[countryId] + dynamicFee;
        require(newTreasuryBalance <= MAX_TREASURY_BALANCE, "Treasury balance too high");
        countryTreasuryBalance[countryId] = newTreasuryBalance;

        _burn(msg.sender, countryId, amount);

        // Instantly pay dev fee
        if (devFee > 0) {
            require(HELLO.transfer(devWallet, devFee), "HELLO transfer failed");
            emit FundsSent(devWallet, devFee);
        }

        // Instantly pay referral reward (or to devWallet if no referrer)
        if (_hasReferrer[msg.sender] && referralReward > 0 && referrers[msg.sender] != address(0)) {
            address actualReferrer = referrers[msg.sender];
            require(HELLO.transfer(actualReferrer, referralReward), "HELLO transfer failed");
            emit ReferralRewardAllocated(actualReferrer, referralReward);
            emit FundsSent(actualReferrer, referralReward);
        } else if (referralReward > 0) {
            require(HELLO.transfer(devWallet, referralReward), "HELLO transfer failed");
            emit FundsSent(devWallet, referralReward);
        }

        // Instantly pay head fee
        if (headFee > 0) {
            address headOwner = _getHeadOwner(countryId);
            if (headOwner == address(0)) headOwner = devWallet;
            require(HELLO.transfer(headOwner, headFee), "HELLO transfer failed");
            emit HeadFeeAllocated(headOwner, headFee);
            emit FundsSent(headOwner, headFee);
        }

        // Pay the seller instantly
        require(HELLO.transfer(msg.sender, netAmount), "HELLO transfer failed");
        emit FundsSent(msg.sender, netAmount);

        emit TokensSold(countryId, msg.sender, amount, netAmount, dynamicFee, devFee);

        helloReceived = netAmount;
        return helloReceived;
    }

    // Withdraw treasury funds (only by game contract)
    function withdrawTreasury(uint256 countryId, address to, uint256 amount) external nonReentrant {
        require(msg.sender == gameContract, "Only game contract can withdraw treasury");
        require(countryId >= 1 && countryId <= totalCountries, "Invalid country ID");
        require(countryTreasuryBalance[countryId] >= amount, "Insufficient treasury balance");
        require(to != address(0), "Invalid recipient address");

        countryTreasuryBalance[countryId] -= amount;

        require(HELLO.transfer(to, amount), "HELLO transfer failed");
        emit TreasuryWithdrawn(countryId, to, amount);
    }

    // Add a new country
    function addCountry(string calldata name) external onlyOwner {
        require(bytes(name).length > 0, "Country name cannot be empty");
        require(totalCountries < MAX_COUNTRIES, "Maximum number of countries reached");

        totalCountries++;
        countryNames[totalCountries] = name;

        emit CountryAdded(totalCountries, name);
    }

    // Set developer wallet
    function setDevWallet(address _devWallet) external onlyOwner {
        require(_devWallet != address(0), "Invalid address");
        address oldWallet = devWallet;
        devWallet = _devWallet;
        emit DevWalletUpdated(oldWallet, _devWallet);
    }

    // Set game contract address
    function setGameContract(address _gameContract) external onlyOwner {
        require(_gameContract != address(0), "Invalid game contract address");
        require(_gameContract.code.length > 0, "Game contract must be a contract");
        address oldGameContract = gameContract;
        gameContract = _gameContract;
        emit GameContractUpdated(oldGameContract, _gameContract);
    }

    // Set token URI
    function setURI(string memory newUri) external onlyOwner {
        _setURI(newUri);
        emit URIUpdated(newUri);
    }

    // Pause contract
    function pause() external onlyOwner {
        _pause();
    }

    // Unpause contract
    function unpause() external onlyOwner {
        _unpause();
    }

    // Get treasury balance for a country
    function getTreasuryBalance(uint256 countryId) external view returns (uint256) {
        require(countryId >= 1 && countryId <= totalCountries, "Invalid country ID");
        return countryTreasuryBalance[countryId];
    }

    // Get summary data for all countries
    function getAllCountrySummary() external view returns (CountrySummary[] memory summaries) {
        summaries = new CountrySummary[](totalCountries);
        for (uint256 i = 1; i <= totalCountries; i++) {
            summaries[i - 1] = CountrySummary({
                countryId: i,
                name: countryNames[i],
                supply: totalSupply(i),
                price: getPrice(i),
                helloLocked: countryHelloLocked[i],
                treasuryBalance: countryTreasuryBalance[i],
                dynamicFee: getDynamicFee(i),
                timestamp: block.timestamp
            });
        }
        return summaries;
    }

    // Get user summary data
    function getUserSummary(address user, uint256[] calldata countryIds) external view returns (UserSummary memory summary) {
        require(user != address(0), "Invalid user address");

        uint256[] memory balances = new uint256[](countryIds.length);

        for (uint256 i = 0; i < countryIds.length; i++) {
            require(countryIds[i] >= 1 && countryIds[i] <= totalCountries, "Invalid country ID");
            balances[i] = balanceOf(user, countryIds[i]);
        }

        summary = UserSummary({
            balances: balances,
            timestamp: block.timestamp
        });

        return summary;
    }

    // Override _update for ERC1155 and ERC1155Supply compatibility
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts
    ) internal override(ERC1155, ERC1155Supply) {
        super._update(from, to, ids, amounts);
    }

    function _powFixed(uint256 x, uint256 n) internal pure returns (uint256 r) {
        r = ONE;
        while (n > 0) {
            if (n & 1 != 0) {
                r = (r * x) / ONE;
            }
            x = (x * x) / ONE;
            n >>= 1;
        }
    }

    // Geometric series sum: r^start + r^{start+1} + … + r^{start+len-1}
    // All values are 1e18-scaled fixed-point.  Returns 1e18-scaled sum.
    function _geomSum(uint256 r, uint256 start, uint256 len) internal pure returns (uint256) {
        if (len == 0) return 0;
        // term0 = r^start
        uint256 term0 = _powFixed(r, start);
        // factor = r^len
        uint256 factor = _powFixed(r, len);
        // We want the result to stay 1e18-scaled. Removing the premature
        // division by ONE keeps the extra 1e18 factor which is cancelled by
        // the denominator (also 1e18-scaled).
        uint256 numerator = term0 * (factor - ONE);      // 1e36-scaled
        uint256 denominator = (r - ONE);                 // 1e18-scaled
        return numerator / denominator;                  // back to 1e18-scaled
    }

    /// @notice Batched ERC-1155 balance lookup. Returns the caller's unstaked
    ///         token balances for the provided `ids` array. Uses the built-in
    ///         ERC-1155 `balanceOfBatch` under the hood.
    function getBalances(address user, uint256[] calldata ids)
        external view
        returns (uint256[] memory balances)
    {
        require(user != address(0), "bad user");
        uint256 len = ids.length;
        address[] memory accounts = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            accounts[i] = user;
        }
        balances = balanceOfBatch(accounts, ids);
    }

    // Set country head ERC721 contract
    function setCountryHeadContract(address _contract) external onlyOwner {
        require(_contract != address(0), "Invalid head contract");
        require(_contract.code.length > 0, "Must be a contract");
        countryHeadContract = _contract;
    }

    function _getHeadOwner(uint256 countryId) internal view returns (address headOwner) {
        if (countryHeadContract != address(0)) {
            try IERC721(countryHeadContract).ownerOf(countryId) returns (address owner) {
                headOwner = owner;
            } catch {
                headOwner = address(0);
            }
        }
    }
}
