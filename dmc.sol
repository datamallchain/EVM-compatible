
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MerkleProofUpgradeable as MerkleProof} from "@openzeppelin/contracts-upgradeable/utils/cryptography/MerkleProofUpgradeable.sol";

contract DMC is Initializable, ERC20Upgradeable, OwnableUpgradeable, UUPSUpgradeable {
    struct Bill {
        address owner;              //  (Order creator)
        uint asset;                 //  (Capacity, size in GB)
        uint price;                 //  (Selling price)
        uint capacity;              //  (Selling unit, less than or equal to asset)
        uint minServiceWeek;
        uint maxServiceWeek;
        uint depositAmount;         //  (Deposit, deducted from msg.sender)
        uint startTime;             //  (Block time of the bill)
    }
    struct Order {
        address user;               //  (User)
        address storager;           //  (Storage provider)
        uint asset;                 //  (Purchased capacity)
        uint price;                 //  (Purchase price)
        uint serviceWeek;           //  (Service period)
        uint userDepositAmount;     //  (User's current deposit)
        uint storageDepositAmount;  //  (Storage provider's deposit)
        bytes32 merkleRoot;         //  (Merkle root of the order)
        uint activeTime;            //  (Delivery start time, time > 0 indicates start of delivery)
        uint startTime;             //  (Block time of the order)
        uint lastWithdrawTime;      //  (Last withdrawal time)
    }
    struct Challenge {
        uint orderId;               //  (Order number to initiate challenge)
        uint index;                 //  (Challenge block number)
        uint challengeFee;          //  (User's challenge fee)
        uint startTime;             //  (Block time of the challenge)
    }

    mapping(uint => Order) private orders;
    mapping(uint => Bill) private bills;
    mapping(uint => Challenge) private challenges;

    uint curBillId;
    uint curOrderId;
    uint curChallengeId;

    address lockAddress;

    event BillCreate(uint indexed billId, address indexed storager);
    event OrderCreate(uint indexed orderId, address indexed user, address indexed storager);
    event OrderStart(uint indexed orderId, address indexed user, address indexed storager);
    event OrderFinish(uint indexed orderId, address indexed user, address indexed storager);
    event ChallengeStart(uint indexed challengeId, address indexed user, address indexed storager);
    event ChallengeEnd(uint indexed challengeId, address indexed user, address indexed storager, bool success);
    // event Withdraw(uint indexed orderId, address indexed storager, uint value);

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
        bills[curBillId++] = Bill(_msgSender(), asset, price, capacity, minServiceWeek, maxServiceWeek, depositAmount, block.timestamp);
        emit BillCreate(billId, _msgSender());
    }

    function cancelBill(uint billId) public {
        Bill memory bill = bills[billId];
        require(bill.owner == _msgSender(), "only bill owner can cancel bill");
        _transfer(lockAddress, _msgSender(), bill.depositAmount);
        delete bills[billId];
    }

    function createOrder(uint billId, uint asset, uint serviceWeek) public {
        Bill memory bill = bills[billId];
        require(bill.owner != address(0), "bill not found");
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
        orders[orderId] = Order(_msgSender(), bill.owner, asset, bill.price, serviceWeek, userDepositAmount, storageDepositAmount, bytes32(0), 0, block.timestamp, 0);
        emit OrderCreate(orderId, _msgSender(), bill.owner);
    }

    function cancelOrder(uint orderId) public {
        Order memory order = orders[orderId];
        require(order.user == _msgSender(), "only order user can cancel order");
        require(order.activeTime > 0, "cannot cancel a active order");
        _transfer(lockAddress, order.user, order.userDepositAmount);
        _transfer(lockAddress, order.storager, order.storageDepositAmount);
        delete orders[orderId];
    }

    function prepareChallenge(uint orderId, bytes32 merkleRoot) public {
        require(merkleRoot != bytes32(0), "must input valid merkle root");
        Order memory order = orders[orderId];
        require(order.activeTime == 0, "order already actived");
        if (_msgSender() == order.user) {
            if (order.merkleRoot == merkleRoot) {
                order.activeTime = block.timestamp;
                order.lastWithdrawTime = block.timestamp;
                emit OrderStart(orderId, order.user, order.storager);
            }
        } else {
            if (_msgSender() == order.storager) {
                order.merkleRoot = merkleRoot;
            } else {
                revert("only order user or storager can prepare");
            }
        }
    }

    function startChallenge(uint orderId, uint index, uint challengeFee) public {
        Order memory order = orders[orderId];
        require(order.user == _msgSender(), "only user can start a challenge");
        require(balanceOf(_msgSender()) >= challengeFee, "Insufficient balance");
        _transfer(_msgSender(), lockAddress, challengeFee);
        uint challengeId = curChallengeId++;
        challenges[challengeId] = Challenge(orderId, index, challengeFee, block.timestamp);
        emit ChallengeStart(challengeId, order.user, order.storager);
    }

    function endChallenge(uint challengeId) public {
        Challenge memory challenge = challenges[challengeId];
        Order memory order = orders[challenge.orderId];
        require(order.user == _msgSender(), "only user can end a challenge");
        require(block.timestamp > challenge.startTime + 7 days, "only can end a challenge after 7 days");
        _transfer(lockAddress, order.user, challenge.challengeFee);

       
        uint userCompensation = order.storageDepositAmount / 2;
        uint forfeitedCompensation = order.storageDepositAmount - userCompensation;
      
        _transfer(lockAddress, order.user, order.userDepositAmount + userCompensation + challenge.challengeFee);
        _transfer(lockAddress, owner(), forfeitedCompensation);

        emit ChallengeEnd(challengeId, order.user, order.storager, false);
        delete orders[challenge.orderId];
        delete challenges[challengeId];
    }

    function proofChallenge(uint challengeId, bytes32 leaf, bytes32[] calldata proofs) public {
        Challenge memory challenge = challenges[challengeId];
        Order memory order = orders[challenge.orderId];
        require(order.storager == _msgSender(), "only storager can proof a challenge");
        bool success = MerkleProof.verify(proofs, order.merkleRoot, leaf);
        if (success) {
            
            _transfer(lockAddress, owner(), challenge.challengeFee);
        } else {
            
            uint userCompensation = order.storageDepositAmount / 2;
            uint forfeitedCompensation = order.storageDepositAmount - userCompensation;
           
            _transfer(lockAddress, order.user, order.userDepositAmount + userCompensation + challenge.challengeFee);
            _transfer(lockAddress, owner(), forfeitedCompensation);
            delete orders[challenge.orderId];
        }
        
        emit ChallengeEnd(challengeId, order.user, order.storager, success);
        delete challenges[challengeId];
    }

    function withdrawOrder(uint orderId) public {
        Order memory order = orders[orderId];
        require(order.storager == _msgSender(), "only storager can withdraw");
        require(order.activeTime > 0, "order not actived");
        uint passedWeek = (block.timestamp - order.lastWithdrawTime) / 1 weeks;
        uint withdrawAmount = order.asset * order.price * passedWeek;
        
        if (order.userDepositAmount < withdrawAmount) {
            
            _transfer(lockAddress, order.storager, order.userDepositAmount);
            emit OrderFinish(orderId, order.user, order.storager);
            delete orders[orderId];
        } else {
            order.userDepositAmount -= withdrawAmount;
            _transfer(lockAddress, order.storager, withdrawAmount);
            order.lastWithdrawTime += passedWeek * 1 weeks;
        }
        
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