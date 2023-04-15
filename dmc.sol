// https://eips.ethereum.org/EIPS/eip-20
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MerkleProofUpgradeable as MerkleProof} from "@openzeppelin/contracts-upgradeable/utils/cryptography/MerkleProofUpgradeable.sol";

contract DMC is Initializable, ERC20Upgradeable, OwnableUpgradeable, UUPSUpgradeable {
    struct Bill {
        address owner;              
        uint asset;                 
        uint price;                 
        uint capacity;              
        uint minServiceWeek;
        uint maxServiceWeek;
        uint depositAmount;         
        uint startTime;             
    }
    struct Order {
        address user;               
        address storager;           
        uint asset;                 
        uint price;                 
        uint serviceWeek;           
        uint userDepositAmount;     
        uint storageDepositAmount;  
        bytes32 merkleRoot;         
        uint128 piece_size;         
        uint128 leaves;             
        uint activeTime;            
        uint startTime;             
        uint lastWithdrawTime;      
        uint billId;                
        address firstPerpare;       
    }
    struct Challenge {
        uint orderId;               
        uint index;                 
        bytes32 mhash;              
        uint startTime;             
    }

    mapping(uint => Order) private orders;
    mapping(uint => Bill) private bills;
    mapping(uint => Challenge) private challenges;
    mapping(address => string) private memos;

    uint curBillId;
    uint curOrderId;
    uint curChallengeId;

    address lockAddress;

    event BillCreate(uint indexed billId, address indexed storager);
    event BillCancel(uint indexed billId, address indexed storager, Bill bill);
    event OrderCreate(uint indexed orderId, address indexed user, address indexed storager);
    event OrderStart(uint indexed orderId, address indexed user, address indexed storager);
    event OrderFinish(uint indexed orderId, address indexed user, address indexed storager, Order order);
    event ChallengeStart(uint indexed challengeId, address indexed user, address indexed storager);
    event ChallengeEnd(uint indexed challengeId, address indexed user, address indexed storager, bool success, Challenge challenge);
    // event Withdraw(uint indexed orderId, address indexed storager, uint value);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(uint256 _initialAmount) initializer public {
        __ERC20_init("DataMallChain", "DMC");
        __Ownable_init();
        __UUPSUpgradeable_init();

        curBillId = 1;
        curOrderId = 1;
        curChallengeId = 1;

        lockAddress = address(1);

        _mint(owner(), _initialAmount * 10 ** decimals());
    }

    function decimals() public view virtual override returns (uint8) {
        return 4;
    }
    
    /*
    function changeLockAddress(address newLockAddress) public onlyOwner {
        if (balanceOf(lockAddress) > 0) {
            _transfer(lockAddress, newLockAddress, balanceOf(lockAddress));
        }
        lockAddress = newLockAddress
    }
    */

    function createBill(uint asset, uint price, uint capacity, uint minServiceWeek, uint maxServiceWeek, uint depositMulti) public {
        uint depositAmount = asset * price * depositMulti;
        require(balanceOf(_msgSender()) >= depositAmount, "Insufficient balance");
        _transfer(_msgSender(), lockAddress, depositAmount);
        uint billId = curBillId++;
        bills[billId] = Bill(_msgSender(), asset, price, capacity, minServiceWeek, maxServiceWeek, depositAmount, block.timestamp);
        emit BillCreate(billId, _msgSender());
    }

    function cancelBill(uint billId) public {
        Bill memory bill = bills[billId];
        require(bill.owner == _msgSender(), "Permission Denied");
        _transfer(lockAddress, _msgSender(), bill.depositAmount);
        emit BillCancel(billId, bill.owner, bill);
        delete bills[billId];
    }

    function createOrder(uint billId, uint asset, uint serviceWeek) public {
        Bill memory bill = bills[billId];
        require(bill.owner != address(0), "NotFound");
        require(asset <= bill.asset, "asset out of scope");
        require(serviceWeek <= bill.maxServiceWeek && serviceWeek >= bill.minServiceWeek, "service week out of scope");
        require(asset % bill.capacity == 0, "asset must be a multiple of capacity");
        uint userDepositAmount = bill.price * asset * serviceWeek;
        require(balanceOf(_msgSender()) >= userDepositAmount, "Insufficient balance");
        _transfer(_msgSender(), lockAddress, userDepositAmount);
        uint storageDepositAmount = bill.depositAmount * asset / bill.asset;
        bill.asset -= asset;
        bill.depositAmount -= storageDepositAmount;
        uint orderId = curOrderId++;
        orders[orderId] = Order(_msgSender(), bill.owner, asset, bill.price, serviceWeek, userDepositAmount, storageDepositAmount, bytes32(0), 0, 0, 0, block.timestamp, 0, billId, address(0));
        emit OrderCreate(orderId, _msgSender(), bill.owner);
        if (bill.asset == 0) {
            emit BillCancel(billId, bill.owner, bill);
            delete bills[billId];
        } else {
            emit BillCreate(billId, bill.owner);
        }
    }

    function cancelOrder(uint orderId) public {
        Order memory order = orders[orderId];
        require(order.user == _msgSender(), "Permission Denied");
        require(order.activeTime > 0, "cannot cancel a active order");
        _transfer(lockAddress, order.user, order.userDepositAmount);
        _transfer(lockAddress, order.storager, order.storageDepositAmount);
        delete orders[orderId];
    }

    function prepareOrder(uint orderId, bytes32 merkleRoot, uint128 piece_size, uint128 leaves) public {
        Order memory order = orders[orderId];
        require(_msgSender() == order.user || _msgSender() == order.storager, "Permission Denied");
        require(merkleRoot != bytes32(0), "must input valid merkle root");
        require(order.activeTime == 0, "order already actived");
        if (order.merkleRoot == bytes32(0)) {
            // first perpare
            order.merkleRoot = merkleRoot;
            order.piece_size = piece_size;
            order.leaves = leaves;
            order.firstPerpare = _msgSender();
        } else {
            // second prepare
            // merkleRoot, piece_size, leaves must match
            if (order.merkleRoot == merkleRoot && order.piece_size == piece_size && order.leaves == leaves) {
                order.activeTime = block.timestamp;
                order.lastWithdrawTime = block.timestamp;
                emit OrderStart(orderId, order.user, order.storager);
            } else {
                revert("order's merkle info mismatch!");
            }
        }
    }

    function startChallenge(uint orderId, uint piece_index, bytes32 mhash, bytes32[] calldata proofs) public {
        Order memory order = orders[orderId];
        require(order.user == _msgSender(), "Permission Denied");
        
        if (MerkleProof.verifyCalldata(proofs, order.merkleRoot, mhash)) {
            uint challengeId = curChallengeId++;
            
            challenges[challengeId] = Challenge(orderId, piece_index, mhash, block.timestamp);
            emit ChallengeStart(challengeId, order.user, order.storager);
        } else {
            revert("merkle verify mismatch!");
        }
        
    }

    function endChallenge(uint challengeId) public {
        Challenge memory challenge = challenges[challengeId];
        Order memory order = orders[challenge.orderId];
        require(order.user == _msgSender(), "Permission Denied");
        require(block.timestamp > challenge.startTime + 7 days, "only can end a challenge after 7 days");

        
        uint userCompensation = order.storageDepositAmount / 2;
        uint forfeitedCompensation = order.storageDepositAmount - userCompensation;
        
        _transfer(lockAddress, order.user, order.userDepositAmount + userCompensation);
        _transfer(lockAddress, owner(), forfeitedCompensation);

        emit OrderFinish(challenge.orderId, order.user, order.storager, order);
        emit ChallengeEnd(challengeId, order.user, order.storager, false, challenge);
        delete orders[challenge.orderId];
        delete challenges[challengeId];
    }

    function proofChallenge(uint challengeId, bytes calldata leaf_data, bytes32[] calldata subpath) public {
        Challenge memory challenge = challenges[challengeId];
        Order memory order = orders[challenge.orderId];
        require(order.storager == _msgSender(), "Permission Denied");
        
        bytes32 leaf_hash = keccak256(leaf_data);
       
        bool success = MerkleProof.verifyCalldata(subpath, challenge.mhash, leaf_hash);
        if (!success) {
            
            uint userCompensation = order.storageDepositAmount / 2;
            uint forfeitedCompensation = order.storageDepositAmount - userCompensation;
            
            _transfer(lockAddress, order.user, order.userDepositAmount + userCompensation);
            _transfer(lockAddress, owner(), forfeitedCompensation);
            emit OrderFinish(challenge.orderId, order.user, order.storager, order);
            delete orders[challenge.orderId];
        }
        
        emit ChallengeEnd(challengeId, order.user, order.storager, success, challenge);
        delete challenges[challengeId];
    }

    function withdrawOrder(uint orderId) public {
        Order memory order = orders[orderId];
        require(order.storager == _msgSender(), "Permission Denied");
        require(order.activeTime > 0, "order not actived");
        uint passedWeek = (block.timestamp - order.lastWithdrawTime) / 1 weeks;
        uint withdrawAmount = order.asset * order.price * passedWeek;
        
        if (order.userDepositAmount < withdrawAmount) {
            
            _transfer(lockAddress, order.storager, order.userDepositAmount);
            emit OrderFinish(orderId, order.user, order.storager, order);
            delete orders[orderId];
        } else {
            order.userDepositAmount -= withdrawAmount;
            _transfer(lockAddress, order.storager, withdrawAmount);
            order.lastWithdrawTime += passedWeek * 1 weeks;
        }
    }

    function set_memo(string calldata memo) public {
        memos[_msgSender()] = memo;
    }

    function get_memo(address user) public view returns(string memory) {
        return memos[user];
    }

    function getBill(uint billId) public view returns(Bill memory) {
        return bills[billId];
    }

    function getOrder(uint orderId) public view returns(Order memory) {
        return orders[orderId];
    }

    function getChallenge(uint challengeId) public view returns(Challenge memory) {
        return challenges[challengeId];
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyOwner
        override
    {}


}