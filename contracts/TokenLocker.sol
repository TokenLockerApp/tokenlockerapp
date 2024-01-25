/**
 * @title TokenLocker.app - Secure liquidity and token locking solution on DeFi
 * @To Use the dApp: https://tokenlocker.app
*/

// #####  ####   #  #  ######  ##    #  #         ####   #####  #  #  ######  ########           ##      #####   #####
//   #   #    #  # #   #       ##    #  #        #    #  #      # #   #       #       #         #  #     #    #  #    #
//   #   #    #  ##    ####    #  #  #  #        #    #  #      ##    ####    ########         ######    #####   #####
//   #   #    #  # #   #       #   # #  #        #    #  #      # #   #       #       #  ##   #      #   #       #
//   #    ####   #  #  ######  #    ##  #######   ####   #####  #  #  ######  #       #  ##  #        #  #       #

// SPDX-License-Identifier: UNLICENSED
// This contract locks uniswap v2 compatible liquidity pair or standard erc20 token. Used to give investors peace of mind a token team has locked liquidity

pragma solidity 0.6.12;

import "./TransferHelper.sol";
import "./EnumerableSet.sol";
import "./SafeMath.sol";
import "./Ownable.sol";
import "./ReentrancyGuard.sol";


interface IUniswapV2Pair {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IUniFactory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}
interface IMigrator {
    function migrate(address lpToken, uint256 amount, uint256 unlockDate, address owner) external returns (bool);
}

contract TokenLockerApp is Ownable, ReentrancyGuard {
  using SafeMath for uint256;
  using EnumerableSet for EnumerableSet.AddressSet;


  struct UserInfo {
    EnumerableSet.AddressSet lockedTokens; // records all tokens the user has locked
    mapping(address => uint256[]) locksForToken; // map erc20 address to lock id for that token
  }

  struct TokenLock {
    uint256 lockDate; // the date the token was locked
    uint256 amount; // the amount of tokens still locked (initialAmount minus withdrawls)
    uint256 initialAmount; // the initial lock amount
    uint256 unlockDate; // the date the token can be withdrawn
    uint256 lockID; // lockID nonce per pair or erc20 token
    address owner;
    bool isLP; // is pair or erc20 token
  }

  mapping(address => UserInfo) private users;

  EnumerableSet.AddressSet private lockedTokens;
  mapping(address => TokenLock[]) public tokenLocks; //map univ2-compatible pair and tokens to all its locks

  EnumerableSet.AddressSet private dexFactoryList;

  struct FeeStruct {
    uint256 ethFee; // Small eth fee to prevent spam on the platform
    uint256 liquidityFee; // fee on liquidity tokens
    uint256 referralPercent; // fee for referrals
    uint256 whitelistFee;
  }
    
  FeeStruct public gFees;
  EnumerableSet.AddressSet private feeWhitelist;

  address payable devaddr;
  
  IMigrator migrator;

  event onDeposit(address indexed lpToken, address indexed user, uint256 amount, uint256 lockDate, uint256 unlockDate, address indexed owner, uint256 lockID, bool isLP);
  event onWithdraw(address indexed lpToken, address indexed user, uint256 amount);
  event onRelock(address lpToken, address user, uint256 lockID, uint256 newDate);
  event onIncrement(address lpToken, address user, uint256 lockID, uint256 _amount);
  event onSplit(address lpToken, address user, uint256 lockID, uint256 _amount);
  event ReferrerRewarded(address indexed user, address indexed addr, uint256 _amount);

  constructor(address[] memory _dexFactoryList) public {
    devaddr = msg.sender;
    gFees.ethFee = 0.01 ether;
    gFees.referralPercent = 200; // 25%
    gFees.liquidityFee = 0; // 0%
    gFees.whitelistFee = 1 ether;
    for(uint i;i<_dexFactoryList.length;i++){
      dexFactoryList.add(_dexFactoryList[i]);
    }
  }
  //For unexpected ether funds
  function claimETH() public onlyOwner{
      devaddr.transfer(address(this).balance);
    //
  }
  
  function setDev(address payable _devaddr) public onlyOwner {
    devaddr = _devaddr;
  }
  
  /**
   * @notice set the migrator contract which allows locked lp tokens to be migrated to Uniswap-compatible v3
   */
  function setMigrator(IMigrator _migrator) public onlyOwner {
    migrator = _migrator;
  }
  
  function setFees( uint256 _ethFee, uint _whitelistFee, uint256 _liquidityFee, uint256 _referralPercent ) public onlyOwner {
    gFees.ethFee = _ethFee;
    gFees.whitelistFee = _whitelistFee;
    gFees.liquidityFee = _liquidityFee;
    gFees.referralPercent = _referralPercent;
    
  }
  
  /**
   * @notice whitelisted dex factory to get supported on locking
   */
  function setDexFactoryList(address _factory, bool _add) public onlyOwner {
    if (_add) {
      dexFactoryList.add(_factory);
    } else {
      dexFactoryList.remove(_factory);
    }
  }

  /**
   * @notice whitelisted accounts dont pay any fee on locking
   */
  function setWhitelist(address _user, bool _add) public onlyOwner {
    if (_add) {
      feeWhitelist.add(_user);
    } else {
      feeWhitelist.remove(_user);
    }
  }

  /**
   * @notice check if a account or token is whitelisted
   */
  function isWhitelisted(address _user) public view returns(bool){
      return feeWhitelist.contains(_user);
  }

  /**
   * @notice apply for whitelist
   */
  function applyForWhitelist () external payable nonReentrant {
    require(msg.value >= gFees.whitelistFee, "FEE NOT MET");
    devaddr.transfer(msg.value);
    feeWhitelist.add(msg.sender);
  }

  /**
   * @notice Creates a new lock
   * @param _lpToken the univ2-compatible pair address
   * @param _amount amount of LP tokens to lock
   * @param _unlock_date the unix timestamp (in seconds) until unlock
   * @param _referral the referrer address if any or address(0) for none
   * @param _withdrawer the user who can withdraw liquidity once the lock expires.
   */
  function lockLPToken (address _lpToken, uint256 _amount, uint256 _unlock_date, address payable _referral, address payable _withdrawer) external payable nonReentrant {
    require(_unlock_date < 10000000000, 'TIMESTAMP INVALID'); // prevents errors when timestamp entered in milliseconds
    require(_amount > 0, 'INSUFFICIENT');

    //ensure this pair is a univ2-compatible pair by querying the factory
    IUniswapV2Pair lpair = IUniswapV2Pair(address(_lpToken));
    address factoryAddress = lpair.factory();
    require(dexFactoryList.contains(factoryAddress), 'DEX NOT SUPPORTED');

    address factoryPairAddress = IUniFactory(factoryAddress).getPair(lpair.token0(), lpair.token1());
    require(factoryPairAddress == address(_lpToken), 'NOT UNIV2');

    _addLock(_lpToken, _amount, _unlock_date, _withdrawer, _referral, true);
  }

  /**
   * @notice Creates a new lock
   * @param _token the token address
   * @param _amount amount of tokens to lock
   * @param _unlock_date the unix timestamp (in seconds) until unlock
   * @param _referral the referrer address if any or address(0) for none
   * @param _withdrawer the user who can withdraw token once the lock expires.
   */
  function lockToken (address _token, uint256 _amount, uint256 _unlock_date, address payable _referral, address payable _withdrawer) external payable nonReentrant {
    require(_unlock_date < 10000000000, 'TIMESTAMP INVALID'); // prevents errors when timestamp entered in milliseconds
    require(_amount > 0, 'INSUFFICIENT');
    
    _addLock(_token, _amount, _unlock_date, _withdrawer, _referral, false);
  }
  
  function _addLock (address _token, uint256 _amount, uint256 _unlock_date, address payable _withdrawer, address payable _referral, bool isLP) internal {
    TransferHelper.safeTransferFrom(_token, address(msg.sender), address(this), _amount);
    // check fees
    uint256 amountLocked = _amount;
    if (!isWhitelisted(msg.sender) && !isWhitelisted(_token)) {
        require(msg.value >= gFees.ethFee, 'FEE NOT MET');
        uint256 devFee = msg.value;
        if (devFee != 0 && _referral != address(0)) { // referral fee
            uint256 referralFee = devFee.mul(gFees.referralPercent).div(1000);
            _referral.transfer(referralFee);
            devFee = devFee.sub(referralFee);
            emit ReferrerRewarded(msg.sender, _referral, referralFee);
        }
        devaddr.transfer(devFee);
      // percent fee
      if(gFees.liquidityFee > 0){
        uint256 liquidityFee = _amount.mul(gFees.liquidityFee).div(1000);
        TransferHelper.safeTransfer(_token, devaddr, liquidityFee);
        amountLocked = _amount.sub(liquidityFee);
      }
        
    } else if (msg.value > 0){
      // refund eth if a whitelisted user sent it by mistake
      msg.sender.transfer(msg.value);
    }

    TokenLock memory token_lock;
    token_lock.lockDate = block.timestamp;
    token_lock.amount = amountLocked;
    token_lock.initialAmount = amountLocked;
    token_lock.unlockDate = _unlock_date;
    token_lock.lockID = tokenLocks[_token].length;
    token_lock.owner = _withdrawer;
    token_lock.isLP = isLP;

    // record the lock for the tokens
    tokenLocks[_token].push(token_lock);
    lockedTokens.add(_token);

    // record the lock for the user
    UserInfo storage user = users[_withdrawer];
    user.lockedTokens.add(_token);
    uint256[] storage user_locks = user.locksForToken[_token];
    user_locks.push(token_lock.lockID);
    
    emit onDeposit(_token, msg.sender, token_lock.amount, token_lock.lockDate, token_lock.unlockDate, token_lock.owner, token_lock.lockID, isLP);
  }
  
  /**
   * @notice extend a lock with a new unlock date, _index and _lockID ensure the correct lock is changed
   * this prevents errors when a user performs multiple tx per block possibly with varying gas prices
   */
  function relock (address _token, uint256 _index, uint256 _lockID, uint256 _unlock_date) external nonReentrant {
    require(_unlock_date < 10000000000, 'TIMESTAMP INVALID'); // prevents errors when timestamp entered in milliseconds
    uint256 lockID = users[msg.sender].locksForToken[_token][_index];
    TokenLock storage userLock = tokenLocks[_token][lockID];
    require(lockID == _lockID && userLock.owner == msg.sender, 'LOCK MISMATCH'); // ensures correct lock is affected
    require(userLock.unlockDate < _unlock_date, 'UNLOCK BEFORE');
    
    uint256 amountLocked = userLock.amount;
    if (!isWhitelisted(msg.sender) && !isWhitelisted(_token)) {
      if(gFees.liquidityFee > 0){
        uint256 liquidityFee = userLock.amount.mul(gFees.liquidityFee).div(1000);
        TransferHelper.safeTransfer(_token, devaddr, liquidityFee);
        amountLocked = userLock.amount.sub(liquidityFee);
      }
          
    }
    userLock.amount = amountLocked;
    userLock.unlockDate = _unlock_date;

    emit onRelock(_token, msg.sender, userLock.lockID, _unlock_date);

  }
  
  /**
   * @notice withdraw a specified amount from a lock. _index and _lockID ensure the correct lock is changed
   * this prevents errors when a user performs multiple tx per block possibly with varying gas prices
   */
  function withdraw (address _token, uint256 _index, uint256 _lockID, uint256 _amount) external nonReentrant {
    require(_amount > 0, 'ZERO WITHDRAWL');
    uint256 lockID = users[msg.sender].locksForToken[_token][_index];
    TokenLock storage userLock = tokenLocks[_token][lockID];
    require(lockID == _lockID && userLock.owner == msg.sender, 'LOCK MISMATCH'); // ensures correct lock is affected
    require(userLock.unlockDate < block.timestamp, 'NOT YET');
    userLock.amount = userLock.amount.sub(_amount);
    
    // clean user storage
    if (userLock.amount == 0) {
      uint256[] storage userLocks = users[msg.sender].locksForToken[_token];
      userLocks[_index] = userLocks[userLocks.length-1];
      userLocks.pop();
      if (userLocks.length == 0) {
        users[msg.sender].lockedTokens.remove(_token);
      }
    }
    
    TransferHelper.safeTransfer(_token, msg.sender, _amount);
    emit onWithdraw(_token, msg.sender, _amount);
  }
  
  /**
   * @notice increase the amount of tokens per a specific lock, this is preferable to creating a new lock, less fees, and faster loading on our live block explorer
   */
  function incrementLock (address _token, uint256 _index, uint256 _lockID, uint256 _amount) external nonReentrant {
    require(_amount > 0, 'ZERO AMOUNT');
    uint256 lockID = users[msg.sender].locksForToken[_token][_index];
    TokenLock storage userLock = tokenLocks[_token][lockID];
    require(lockID == _lockID && userLock.owner == msg.sender, 'LOCK MISMATCH'); // ensures correct lock is affected
    
    TransferHelper.safeTransferFrom(_token, address(msg.sender), address(this), _amount);
    
    uint256 amountLocked = _amount;
    if (!isWhitelisted(msg.sender) && !isWhitelisted(_token)) {
        if(gFees.liquidityFee > 0){
          uint256 liquidityFee = _amount.mul(gFees.liquidityFee).div(1000);
          TransferHelper.safeTransfer(_token, devaddr, liquidityFee);
          amountLocked = _amount.sub(liquidityFee);
        }
          
    }
    
    userLock.amount = userLock.amount.add(amountLocked);

    emit onIncrement(_token, msg.sender, userLock.lockID, _amount);


  }
  
  /**
   * @notice split a lock into two seperate locks, useful when a lock is about to expire and youd like to relock a portion
   * and withdraw a smaller portion
   */
  function splitLock (address _token, uint256 _index, uint256 _lockID, uint256 _amount) external payable nonReentrant {
    require(_amount > 0, 'ZERO AMOUNT');
    uint256 lockID = users[msg.sender].locksForToken[_token][_index];
    TokenLock storage userLock = tokenLocks[_token][lockID];
    require(lockID == _lockID && userLock.owner == msg.sender, 'LOCK MISMATCH'); // ensures correct lock is affected
    
    require(msg.value >= gFees.ethFee, 'FEE NOT MET');
    devaddr.transfer(msg.value);
    
    userLock.amount = userLock.amount.sub(_amount);
    
    TokenLock memory token_lock;
    token_lock.lockDate = userLock.lockDate;
    token_lock.amount = _amount;
    token_lock.initialAmount = _amount;
    token_lock.unlockDate = userLock.unlockDate;
    token_lock.lockID = tokenLocks[_token].length;
    token_lock.owner = msg.sender;
    token_lock.isLP = userLock.isLP;

    // record the lock for the token
    tokenLocks[_token].push(token_lock);

    // record the lock for the user
    UserInfo storage user = users[msg.sender];
    uint256[] storage user_locks = user.locksForToken[_token];
    user_locks.push(token_lock.lockID);


    
    emit onSplit(_token, msg.sender, _lockID, _amount);

    emit onDeposit(_token, msg.sender, token_lock.amount, token_lock.lockDate, token_lock.unlockDate, token_lock.owner, token_lock.lockID, token_lock.isLP);

  }
  
  /**
   * @notice transfer a lock to a new owner, e.g. presale project -> project owner
   */
  function transferLockOwnership (address _lpToken, uint256 _index, uint256 _lockID, address payable _newOwner) external {
    require(msg.sender != _newOwner, 'OWNER');
    uint256 lockID = users[msg.sender].locksForToken[_lpToken][_index];
    TokenLock storage transferredLock = tokenLocks[_lpToken][lockID];
    require(lockID == _lockID && transferredLock.owner == msg.sender, 'LOCK MISMATCH'); // ensures correct lock is affected
    
    // record the lock for the new Owner
    UserInfo storage user = users[_newOwner];
    user.lockedTokens.add(_lpToken);
    uint256[] storage user_locks = user.locksForToken[_lpToken];
    user_locks.push(transferredLock.lockID);
    
    // remove the lock from the old owner
    uint256[] storage userLocks = users[msg.sender].locksForToken[_lpToken];
    userLocks[_index] = userLocks[userLocks.length-1];
    userLocks.pop();
    if (userLocks.length == 0) {
      users[msg.sender].lockedTokens.remove(_lpToken);
    }
    transferredLock.owner = _newOwner;
  }
  
  /**
   * @notice migrates liquidity to uniswap v3
   */
  function migrate (address _lpToken, uint256 _index, uint256 _lockID, uint256 _amount) external nonReentrant {
    require(address(migrator) != address(0), "NOT SET");
    require(_amount > 0, 'ZERO MIGRATION');
    
    uint256 lockID = users[msg.sender].locksForToken[_lpToken][_index];
    TokenLock storage userLock = tokenLocks[_lpToken][lockID];
    require(lockID == _lockID && userLock.owner == msg.sender, 'LOCK MISMATCH'); // ensures correct lock is affected
    userLock.amount = userLock.amount.sub(_amount);
    
    // clean user storage
    if (userLock.amount == 0) {
      uint256[] storage userLocks = users[msg.sender].locksForToken[_lpToken];
      userLocks[_index] = userLocks[userLocks.length-1];
      userLocks.pop();
      if (userLocks.length == 0) {
        users[msg.sender].lockedTokens.remove(_lpToken);
      }
    }
    TransferHelper.safeApprove(_lpToken, address(migrator), _amount);
    migrator.migrate(_lpToken, _amount, userLock.unlockDate, msg.sender);
  }
  
  function getNumLocksForToken (address _token) external view returns (uint256) {
    return tokenLocks[_token].length;
  }
  
  function getNumLockedTokens () external view returns (uint256) {
    return lockedTokens.length();
  }
  
  function getLockedTokenAtIndex (uint256 _index) external view returns (address) {
    return lockedTokens.at(_index);
  }

  // user functions
  function getUserNumLockedTokens (address _user) external view returns (uint256) {
    UserInfo storage user = users[_user];
    return user.lockedTokens.length();
  }
  
  function getUserLockedTokenAtIndex (address _user, uint256 _index) external view returns (address) {
    UserInfo storage user = users[_user];
    return user.lockedTokens.at(_index);
  }

  function getUserNumLocksForToken (address _user, address _token) external view returns (uint256) {
    UserInfo storage user = users[_user];
    return user.locksForToken[_token].length;
  }
  
  function getUserLockForTokenAtIndex (address _user, address _token, uint256 _index) external view 
  returns (uint256, uint256, uint256, uint256, uint256, address, bool isLP) {
    uint256 lockID = users[_user].locksForToken[_token][_index];
    TokenLock storage tokenLock = tokenLocks[_token][lockID];
    return (tokenLock.lockDate, tokenLock.amount, tokenLock.initialAmount, tokenLock.unlockDate, tokenLock.lockID, tokenLock.owner, tokenLock.isLP);
  }

  //dex factory functions
   function getDexFactoryListLength () external view returns (uint256) {
    return dexFactoryList.length();
  }

  function getDexFactoryAtIndex (uint256 _index) external view returns (address) {
    return dexFactoryList.at(_index);
  }

  function getDexFactorySupported (address _factory) external view returns (bool) {
    return dexFactoryList.contains(_factory);
  }

}
