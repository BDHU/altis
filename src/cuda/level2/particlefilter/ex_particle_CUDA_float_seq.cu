////////////////////////////////////////////////////////////////////////////////////////////////////
// file:	altis\src\cuda\level2\particlefilter\ex_particle_CUDA_float_seq.cu
//
// summary:	Exception particle cuda float sequence class
// 
// origin: Rodinia (http://rodinia.cs.virginia.edu/doku.php)
////////////////////////////////////////////////////////////////////////////////////////////////////

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <math.h>
#include <unistd.h>
#include <fcntl.h>
#include <float.h>
#include <time.h>
#include <sys/time.h>
#include "OptionParser.h"
#include "ResultDatabase.h"
#include "cudacommon.h"
#define BLOCK_X 16
#define BLOCK_Y 16
#define PI 3.1415926535897932

const int threads_per_block = 512;

bool verbose = false;
bool quiet = false;

/**
@var M value for Linear Congruential Generator (LCG); use GCC's value
 */
long M = INT_MAX;
/**
@var A value for LCG
 */
int A = 1103515245;
/**
@var C value for LCG
 */
int C = 12345;

double get_wall_time(){
    struct timeval time;
    if (gettimeofday(&time,NULL)){
        return 0;
    }
    return (double)time.tv_sec + (double)time.tv_usec * .000001;
}

/********************************
 * CALC LIKELIHOOD SUM
 * DETERMINES THE LIKELIHOOD SUM BASED ON THE FORMULA: SUM( (IK[IND] - 100)^2 - (IK[IND] - 228)^2)/ 100
 * param 1 I 3D matrix
 * param 2 current ind array
 * param 3 length of ind array
 * returns a double representing the sum
 ********************************/
__device__ double calcLikelihoodSum(unsigned char * I, int * ind, int numOnes, int index) {
    double likelihoodSum = 0.0;
    int x;
    for (x = 0; x < numOnes; x++)
        likelihoodSum += (pow((double) (I[ind[index * numOnes + x]] - 100), 2) - pow((double) (I[ind[index * numOnes + x]] - 228), 2)) / 50.0;
    return likelihoodSum;
}

/****************************
CDF CALCULATE
CALCULATES CDF
param1 CDF
param2 weights
param3 Nparticles
 *****************************/
__device__ void cdfCalc(double * CDF, double * weights, int Nparticles) {
    int x;
    CDF[0] = weights[0];
    for (x = 1; x < Nparticles; x++) {
        CDF[x] = weights[x] + CDF[x - 1];
    }
}

/*****************************
 * RANDU
 * GENERATES A UNIFORM DISTRIBUTION
 * returns a double representing a randomily generated number from a uniform distribution with range [0, 1)
 ******************************/
__device__ double d_randu(int * seed, int index) {

    int M = INT_MAX;
    int A = 1103515245;
    int C = 12345;
    int num = A * seed[index] + C;
    seed[index] = num % M;

    return fabs(seed[index] / ((double) M));
}/**
* Generates a uniformly distributed random number using the provided seed and GCC's settings for the Linear Congruential Generator (LCG)
* @see http://en.wikipedia.org/wiki/Linear_congruential_generator
* @note This function is thread-safe
* @param seed The seed array
* @param index The specific index of the seed to be advanced
* @return a uniformly distributed number [0, 1)
*/

double randu(int * seed, int index) {
    int num = A * seed[index] + C;
    seed[index] = num % M;
    return fabs(seed[index] / ((double) M));
}

/**
 * Generates a normally distributed random number using the Box-Muller transformation
 * @note This function is thread-safe
 * @param seed The seed array
 * @param index The specific index of the seed to be advanced
 * @return a double representing random number generated using the Box-Muller algorithm
 * @see http://en.wikipedia.org/wiki/Normal_distribution, section computing value for normal random distribution
 */
double randn(int * seed, int index) {
    /*Box-Muller algorithm*/
    double u = randu(seed, index);
    double v = randu(seed, index);
    double cosine = cos(2 * PI * v);
    double rt = -2 * log(u);
    return sqrt(rt) * cosine;
}

double test_randn(int * seed, int index) {
    //Box-Muller algortihm
    double pi = 3.14159265358979323846;
    double u = randu(seed, index);
    double v = randu(seed, index);
    double cosine = cos(2 * pi * v);
    double rt = -2 * log(u);
    return sqrt(rt) * cosine;
}

__device__ double d_randn(int * seed, int index) {
    //Box-Muller algortihm
    double pi = 3.14159265358979323846;
    double u = d_randu(seed, index);
    double v = d_randu(seed, index);
    double cosine = cos(2 * pi * v);
    double rt = -2 * log(u);
    return sqrt(rt) * cosine;
}

/****************************
UPDATE WEIGHTS
UPDATES WEIGHTS
param1 weights
param2 likelihood
param3 Nparticles
 ****************************/
__device__ double updateWeights(double * weights, double * likelihood, int Nparticles) {
    int x;
    double sum = 0;
    for (x = 0; x < Nparticles; x++) {
        weights[x] = weights[x] * exp(likelihood[x]);
        sum += weights[x];
    }
    return sum;
}

__device__ int findIndexBin(double * CDF, int beginIndex, int endIndex, double value) {
    if (endIndex < beginIndex)
        return -1;
    int middleIndex;
    while (endIndex > beginIndex) {
        middleIndex = beginIndex + ((endIndex - beginIndex) / 2);
        if (CDF[middleIndex] >= value) {
            if (middleIndex == 0)
                return middleIndex;
            else if (CDF[middleIndex - 1] < value)
                return middleIndex;
            else if (CDF[middleIndex - 1] == value) {
                while (CDF[middleIndex] == value && middleIndex >= 0)
                    middleIndex--;
                middleIndex++;
                return middleIndex;
            }
        }
        if (CDF[middleIndex] > value)
            endIndex = middleIndex - 1;
        else
            beginIndex = middleIndex + 1;
    }
    return -1;
}

/** added this function. was missing in original double version.
 * Takes in a double and returns an integer that approximates to that double
 * @return if the mantissa < .5 => return value < input value; else return value > input value
 */
__device__ double dev_round_double(double value) {
    int newValue = (int) (value);
    if (value - newValue < .5f)
        return newValue;
    else
        return newValue++;
}

/*****************************
 * CUDA Find Index Kernel Function to replace FindIndex
 * param1: arrayX
 * param2: arrayY
 * param3: CDF
 * param4: u
 * param5: xj
 * param6: yj
 * param7: weights
 * param8: Nparticles
 *****************************/
__global__ void find_index_kernel(double * arrayX, double * arrayY, double * CDF, double * u, double * xj, double * yj, double * weights, int Nparticles) {
    int block_id = blockIdx.x;
    int i = blockDim.x * block_id + threadIdx.x;

    if (i < Nparticles) {

        int index = -1;
        int x;

        for (x = 0; x < Nparticles; x++) {
            if (CDF[x] >= u[i]) {
                index = x;
                break;
            }
        }
        if (index == -1) {
            index = Nparticles - 1;
        }

        xj[i] = arrayX[index];
        yj[i] = arrayY[index];

        //weights[i] = 1 / ((double) (Nparticles)); //moved this code to the beginning of likelihood kernel

    }
    __syncthreads();
}

__global__ void normalize_weights_kernel(double * weights, int Nparticles, double* partial_sums, double * CDF, double * u, int * seed) {
    int block_id = blockIdx.x;
    int i = blockDim.x * block_id + threadIdx.x;
    __shared__ double u1, sumWeights;
    
    if(0 == threadIdx.x)
        sumWeights = partial_sums[0];
    
    __syncthreads();
    
    if (i < Nparticles) {
        weights[i] = weights[i] / sumWeights;
    }
    
    __syncthreads(); 
    
    if (i == 0) {
        cdfCalc(CDF, weights, Nparticles);
        u[0] = (1 / ((double) (Nparticles))) * d_randu(seed, i); // do this to allow all threads in all blocks to use the same u1
    }
    
    __syncthreads();
    
    if(0 == threadIdx.x) 
        u1 = u[0];
    
    __syncthreads();
        
    if (i < Nparticles) {
        u[i] = u1 + i / ((double) (Nparticles));
    }
}

__global__ void sum_kernel(double* partial_sums, int Nparticles) {
    int block_id = blockIdx.x;
    int i = blockDim.x * block_id + threadIdx.x;

    if (i == 0) {
        int x;
        double sum = 0.0;
        int num_blocks = ceil((double) Nparticles / (double) threads_per_block);
        for (x = 0; x < num_blocks; x++) {
            sum += partial_sums[x];
        }
        partial_sums[0] = sum;
    }
}

/*****************************
 * CUDA Likelihood Kernel Function to replace FindIndex
 * param1: arrayX
 * param2: arrayY
 * param2.5: CDF
 * param3: ind
 * param4: objxy
 * param5: likelihood
 * param6: I
 * param6.5: u
 * param6.75: weights
 * param7: Nparticles
 * param8: countOnes
 * param9: max_size
 * param10: k
 * param11: IszY
 * param12: Nfr
 *****************************/
__global__ void likelihood_kernel(double * arrayX, double * arrayY, double * xj, double * yj, double * CDF, int * ind, int * objxy, double * likelihood, unsigned char * I, double * u, double * weights, int Nparticles, int countOnes, int max_size, int k, int IszY, int Nfr, int *seed, double* partial_sums) {
    int block_id = blockIdx.x;
    int i = blockDim.x * block_id + threadIdx.x;
    int y;
    
    int indX, indY; 
    __shared__ double buffer[512];
    if (i < Nparticles) {
        arrayX[i] = xj[i]; 
        arrayY[i] = yj[i]; 

        weights[i] = 1 / ((double) (Nparticles)); //Donnie - moved this line from end of find_index_kernel to prevent all weights from being reset before calculating position on final iteration.

        arrayX[i] = arrayX[i] + 1.0 + 5.0 * d_randn(seed, i);
        arrayY[i] = arrayY[i] - 2.0 + 2.0 * d_randn(seed, i);
        
    }

    __syncthreads();

    if (i < Nparticles) {
        for (y = 0; y < countOnes; y++) {
            //added dev_round_double() to be consistent with roundDouble
            indX = dev_round_double(arrayX[i]) + objxy[y * 2 + 1];
            indY = dev_round_double(arrayY[i]) + objxy[y * 2];
            
            ind[i * countOnes + y] = abs(indX * IszY * Nfr + indY * Nfr + k);
            if (ind[i * countOnes + y] >= max_size)
                ind[i * countOnes + y] = 0;
        }
        likelihood[i] = calcLikelihoodSum(I, ind, countOnes, i);
        
        likelihood[i] = likelihood[i] / countOnes;
        
        weights[i] = weights[i] * exp(likelihood[i]); //Donnie Newell - added the missing exponential function call
        
    }

    buffer[threadIdx.x] = 0.0;

    __syncthreads();

    if (i < Nparticles) {

        buffer[threadIdx.x] = weights[i];
    }

    __syncthreads();

    //this doesn't account for the last block that isn't full
    for (unsigned int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (threadIdx.x < s) {
            buffer[threadIdx.x] += buffer[threadIdx.x + s];
        }
        
        __syncthreads();
            
    }
    if (threadIdx.x == 0) {
        partial_sums[blockIdx.x] = buffer[0];
    }
    
    __syncthreads();

    
}

/** 
 * Takes in a double and returns an integer that approximates to that double
 * @return if the mantissa < .5 => return value < input value; else return value > input value
 */
double roundDouble(double value) {
    int newValue = (int) (value);
    if (value - newValue < .5)
        return newValue;
    else
        return newValue++;
}

/**
 * Set values of the 3D array to a newValue if that value is equal to the testValue
 * @param testValue The value to be replaced
 * @param newValue The value to replace testValue with
 * @param array3D The image vector
 * @param dimX The x dimension of the frame
 * @param dimY The y dimension of the frame
 * @param dimZ The number of frames
 */
void setIf(int testValue, int newValue, unsigned char * array3D, int * dimX, int * dimY, int * dimZ) {
    int x, y, z;
    for (x = 0; x < *dimX; x++) {
        for (y = 0; y < *dimY; y++) {
            for (z = 0; z < *dimZ; z++) {
                if (array3D[x * *dimY * *dimZ + y * *dimZ + z] == testValue)
                    array3D[x * *dimY * *dimZ + y * *dimZ + z] = newValue;
            }
        }
    }
}

/**
 * Sets values of 3D matrix using randomly generated numbers from a normal distribution
 * @param array3D The video to be modified
 * @param dimX The x dimension of the frame
 * @param dimY The y dimension of the frame
 * @param dimZ The number of frames
 * @param seed The seed array
 */
void addNoise(unsigned char * array3D, int * dimX, int * dimY, int * dimZ, int * seed) {
    int x, y, z;
    for (x = 0; x < *dimX; x++) {
        for (y = 0; y < *dimY; y++) {
            for (z = 0; z < *dimZ; z++) {
                array3D[x * *dimY * *dimZ + y * *dimZ + z] = array3D[x * *dimY * *dimZ + y * *dimZ + z] + (unsigned char) (5 * randn(seed, 0));
            }
        }
    }
}

/**
 * Fills a radius x radius matrix representing the disk
 * @param disk The pointer to the disk to be made
 * @param radius  The radius of the disk to be made
 */
void strelDisk(int * disk, int radius) {
    int diameter = radius * 2 - 1;
    int x, y;
    for (x = 0; x < diameter; x++) {
        for (y = 0; y < diameter; y++) {
            double distance = sqrt(pow((double) (x - radius + 1), 2) + pow((double) (y - radius + 1), 2));
            if (distance < radius) {
                disk[x * diameter + y] = 1;
            } else {
                disk[x * diameter + y] = 0;
            }
        }
    }
}

/**
 * Dilates the provided video
 * @param matrix The video to be dilated
 * @param posX The x location of the pixel to be dilated
 * @param posY The y location of the pixel to be dilated
 * @param poxZ The z location of the pixel to be dilated
 * @param dimX The x dimension of the frame
 * @param dimY The y dimension of the frame
 * @param dimZ The number of frames
 * @param error The error radius
 */
void dilate_matrix(unsigned char * matrix, int posX, int posY, int posZ, int dimX, int dimY, int dimZ, int error) {
    int startX = posX - error;
    while (startX < 0)
        startX++;
    int startY = posY - error;
    while (startY < 0)
        startY++;
    int endX = posX + error;
    while (endX > dimX)
        endX--;
    int endY = posY + error;
    while (endY > dimY)
        endY--;
    int x, y;
    for (x = startX; x < endX; x++) {
        for (y = startY; y < endY; y++) {
            double distance = sqrt(pow((double) (x - posX), 2) + pow((double) (y - posY), 2));
            if (distance < error)
                matrix[x * dimY * dimZ + y * dimZ + posZ] = 1;
        }
    }
}

/**
 * Dilates the target matrix using the radius as a guide
 * @param matrix The reference matrix
 * @param dimX The x dimension of the video
 * @param dimY The y dimension of the video
 * @param dimZ The z dimension of the video
 * @param error The error radius to be dilated
 * @param newMatrix The target matrix
 */
void imdilate_disk(unsigned char * matrix, int dimX, int dimY, int dimZ, int error, unsigned char * newMatrix) {
    int x, y, z;
    for (z = 0; z < dimZ; z++) {
        for (x = 0; x < dimX; x++) {
            for (y = 0; y < dimY; y++) {
                if (matrix[x * dimY * dimZ + y * dimZ + z] == 1) {
                    dilate_matrix(newMatrix, x, y, z, dimX, dimY, dimZ, error);
                }
            }
        }
    }
}

/**
 * Fills a 2D array describing the offsets of the disk object
 * @param se The disk object
 * @param numOnes The number of ones in the disk
 * @param neighbors The array that will contain the offsets
 * @param radius The radius used for dilation
 */
void getneighbors(int * se, int numOnes, int * neighbors, int radius) {
    int x, y;
    int neighY = 0;
    int center = radius - 1;
    int diameter = radius * 2 - 1;
    for (x = 0; x < diameter; x++) {
        for (y = 0; y < diameter; y++) {
            if (se[x * diameter + y]) {
                neighbors[neighY * 2] = (int) (y - center);
                neighbors[neighY * 2 + 1] = (int) (x - center);
                neighY++;
            }
        }
    }
}

/**
 * The synthetic video sequence we will work with here is composed of a
 * single moving object, circular in shape (fixed radius)
 * The motion here is a linear motion
 * the foreground intensity and the background intensity is known
 * the image is corrupted with zero mean Gaussian noise
 * @param I The video itself
 * @param IszX The x dimension of the video
 * @param IszY The y dimension of the video
 * @param Nfr The number of frames of the video
 * @param seed The seed array used for number generation
 */
void videoSequence(unsigned char * I, int IszX, int IszY, int Nfr, int * seed) {
    int k;
    int max_size = IszX * IszY * Nfr;
    /*get object centers*/
    int x0 = (int) roundDouble(IszY / 2.0);
    int y0 = (int) roundDouble(IszX / 2.0);
    I[x0 * IszY * Nfr + y0 * Nfr + 0] = 1;

    /*move point*/
    int xk, yk, pos;
    for (k = 1; k < Nfr; k++) {
        xk = abs(x0 + (k-1));
        yk = abs(y0 - 2 * (k-1));
        pos = yk * IszY * Nfr + xk * Nfr + k;
        if (pos >= max_size)
            pos = 0;
        I[pos] = 1;
    }

    /*dilate matrix*/
    unsigned char * newMatrix = (unsigned char *) malloc(sizeof (unsigned char) * IszX * IszY * Nfr);
    imdilate_disk(I, IszX, IszY, Nfr, 5, newMatrix);
    int x, y;
    for (x = 0; x < IszX; x++) {
        for (y = 0; y < IszY; y++) {
            for (k = 0; k < Nfr; k++) {
                I[x * IszY * Nfr + y * Nfr + k] = newMatrix[x * IszY * Nfr + y * Nfr + k];
            }
        }
    }
    free(newMatrix);

    /*define background, add noise*/
    setIf(0, 100, I, &IszX, &IszY, &Nfr);
    setIf(1, 228, I, &IszX, &IszY, &Nfr);
    /*add noise*/
    addNoise(I, &IszX, &IszY, &Nfr, seed);

}

/**
 * Finds the first element in the CDF that is greater than or equal to the provided value and returns that index
 * @note This function uses sequential search
 * @param CDF The CDF
 * @param lengthCDF The length of CDF
 * @param value The value to be found
 * @return The index of value in the CDF; if value is never found, returns the last index
 */
int findIndex(double * CDF, int lengthCDF, double value) {
    int index = -1;
    int x;
    for (x = 0; x < lengthCDF; x++) {
        if (CDF[x] >= value) {
            index = x;
            break;
        }
    }
    if (index == -1) {
        return lengthCDF - 1;
    }
    return index;
}

/**
 * The implementation of the particle filter using OpenMP for many frames
 * @see http://openmp.org/wp/
 * @note This function is designed to work with a video of several frames. In addition, it references a provided MATLAB function which takes the video, the objxy matrix and the x and y arrays as arguments and returns the likelihoods
 * @param I The video to be run
 * @param IszX The x dimension of the video
 * @param IszY The y dimension of the video
 * @param Nfr The number of frames
 * @param seed The seed array used for random number generation
 * @param Nparticles The number of particles to be used
 */
void particleFilter(unsigned char * I, int IszX, int IszY, int Nfr, int * seed, int Nparticles, ResultDatabase &resultDB) {

    float kernelTime = 0.0f;
    float transferTime = 0.0f;
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    float elapsedTime;

    int max_size = IszX * IszY*Nfr;
    //original particle centroid
    double xe = roundDouble(IszY / 2.0);
    double ye = roundDouble(IszX / 2.0);

    //expected object locations, compared to center
    int radius = 5;
    int diameter = radius * 2 - 1;
    int * disk = (int*) malloc(diameter * diameter * sizeof (int));
    strelDisk(disk, radius);
    int countOnes = 0;
    int x, y;
    for (x = 0; x < diameter; x++) {
        for (y = 0; y < diameter; y++) {
            if (disk[x * diameter + y] == 1)
                countOnes++;
        }
    }
    int * objxy = (int *) malloc(countOnes * 2 * sizeof (int));
    getneighbors(disk, countOnes, objxy, radius);
    //initial weights are all equal (1/Nparticles)
    double * weights = (double *) malloc(sizeof (double) *Nparticles);
    for (x = 0; x < Nparticles; x++) {
        weights[x] = 1 / ((double) (Nparticles));
    }

    //initial likelihood to 0.0
    double * likelihood = (double *) malloc(sizeof (double) *Nparticles);
    double * arrayX = (double *) malloc(sizeof (double) *Nparticles);
    double * arrayY = (double *) malloc(sizeof (double) *Nparticles);
    double * xj = (double *) malloc(sizeof (double) *Nparticles);
    double * yj = (double *) malloc(sizeof (double) *Nparticles);
    double * CDF = (double *) malloc(sizeof (double) *Nparticles);

    //GPU copies of arrays
    double * arrayX_GPU;
    double * arrayY_GPU;
    double * xj_GPU;
    double * yj_GPU;
    double * CDF_GPU;
    double * likelihood_GPU;
    unsigned char * I_GPU;
    double * weights_GPU;
    int * objxy_GPU;

    int * ind = (int*) malloc(sizeof (int) *countOnes * Nparticles);
    int * ind_GPU;
    double * u = (double *) malloc(sizeof (double) *Nparticles);
    double * u_GPU;
    int * seed_GPU;
    double* partial_sums;

    //CUDA memory allocation
    CUDA_SAFE_CALL(cudaMalloc((void **) &arrayX_GPU, sizeof (double) *Nparticles));
    CUDA_SAFE_CALL(cudaMalloc((void **) &arrayY_GPU, sizeof (double) *Nparticles));
    CUDA_SAFE_CALL(cudaMalloc((void **) &xj_GPU, sizeof (double) *Nparticles));
    CUDA_SAFE_CALL(cudaMalloc((void **) &yj_GPU, sizeof (double) *Nparticles));
    CUDA_SAFE_CALL(cudaMalloc((void **) &CDF_GPU, sizeof (double) *Nparticles));
    CUDA_SAFE_CALL(cudaMalloc((void **) &u_GPU, sizeof (double) *Nparticles));
    CUDA_SAFE_CALL(cudaMalloc((void **) &likelihood_GPU, sizeof (double) *Nparticles));
    //set likelihood to zero
    CUDA_SAFE_CALL(cudaMemset((void *) likelihood_GPU, 0, sizeof (double) *Nparticles));
    CUDA_SAFE_CALL(cudaMalloc((void **) &weights_GPU, sizeof (double) *Nparticles));
    CUDA_SAFE_CALL(cudaMalloc((void **) &I_GPU, sizeof (unsigned char) *IszX * IszY * Nfr));
    CUDA_SAFE_CALL(cudaMalloc((void **) &objxy_GPU, sizeof (int) *2 * countOnes));
    CUDA_SAFE_CALL(cudaMalloc((void **) &ind_GPU, sizeof (int) *countOnes * Nparticles));
    CUDA_SAFE_CALL(cudaMalloc((void **) &seed_GPU, sizeof (int) *Nparticles));
    CUDA_SAFE_CALL(cudaMalloc((void **) &partial_sums, sizeof (double) *Nparticles));


    //Donnie - this loop is different because in this kernel, arrayX and arrayY
    //  are set equal to xj before every iteration, so effectively, arrayX and 
    //  arrayY will be set to xe and ye before the first iteration.
    for (x = 0; x < Nparticles; x++) {

        xj[x] = xe;
        yj[x] = ye;

    }

    int k;
    //start send
    cudaEventRecord(start, 0);

    CUDA_SAFE_CALL(cudaMemcpy(I_GPU, I, sizeof (unsigned char) *IszX * IszY*Nfr, cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(objxy_GPU, objxy, sizeof (int) *2 * countOnes, cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(weights_GPU, weights, sizeof (double) *Nparticles, cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(xj_GPU, xj, sizeof (double) *Nparticles, cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(yj_GPU, yj, sizeof (double) *Nparticles, cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(seed_GPU, seed, sizeof (int) *Nparticles, cudaMemcpyHostToDevice));
    int num_blocks = ceil((double) Nparticles / (double) threads_per_block);
    
    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&elapsedTime, start, stop);
    transferTime += elapsedTime * 1.e-3;


    double wall1 = get_wall_time();
    for (k = 1; k < Nfr; k++) {
        
        cudaEventRecord(start, 0);
        likelihood_kernel << < num_blocks, threads_per_block >> > (arrayX_GPU,
                arrayY_GPU, xj_GPU, yj_GPU, CDF_GPU, ind_GPU, objxy_GPU,
                likelihood_GPU, I_GPU, u_GPU, weights_GPU, Nparticles,
                countOnes, max_size, k, IszY, Nfr, seed_GPU, partial_sums);
        sum_kernel << < num_blocks, threads_per_block >> > (partial_sums, Nparticles);
        normalize_weights_kernel << < num_blocks, threads_per_block >> > (weights_GPU, Nparticles, partial_sums, CDF_GPU, u_GPU, seed_GPU);
        find_index_kernel << < num_blocks, threads_per_block >> > (arrayX_GPU, arrayY_GPU, CDF_GPU, u_GPU, xj_GPU, yj_GPU, weights_GPU, Nparticles);
        cudaEventRecord(stop, 0);
        cudaEventSynchronize(stop);
        cudaEventElapsedTime(&elapsedTime, start, stop);
        kernelTime += elapsedTime * 1.e-3;
        CHECK_CUDA_ERROR();

    }//end loop

    //block till kernels are finished
    cudaDeviceSynchronize();
    double wall2 = get_wall_time();

    cudaFree(xj_GPU);
    cudaFree(yj_GPU);
    cudaFree(CDF_GPU);
    cudaFree(u_GPU);
    cudaFree(likelihood_GPU);
    cudaFree(I_GPU);
    cudaFree(objxy_GPU);
    cudaFree(ind_GPU);
    cudaFree(seed_GPU);
    cudaFree(partial_sums);

    cudaEventRecord(start, 0);
    CUDA_SAFE_CALL(cudaMemcpy(arrayX, arrayX_GPU, sizeof (double) *Nparticles, cudaMemcpyDeviceToHost));
    CUDA_SAFE_CALL(cudaMemcpy(arrayY, arrayY_GPU, sizeof (double) *Nparticles, cudaMemcpyDeviceToHost));
    CUDA_SAFE_CALL(cudaMemcpy(weights, weights_GPU, sizeof (double) *Nparticles, cudaMemcpyDeviceToHost));
    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&elapsedTime, start, stop);
    transferTime += elapsedTime * 1.e-3;

    xe = 0;
    ye = 0;
    // estimate the object location by expected values
    for (x = 0; x < Nparticles; x++) {
        xe += arrayX[x] * weights[x];
        ye += arrayY[x] * weights[x];
    }
    if(verbose && !quiet) {
        printf("XE: %lf\n", xe);
        printf("YE: %lf\n", ye);
        double distance = sqrt(pow((double) (xe - (int) roundDouble(IszY / 2.0)), 2) + pow((double) (ye - (int) roundDouble(IszX / 2.0)), 2));
        printf("%lf\n", distance);
    }
    
    char atts[1024];
    sprintf(atts, "dimx:%d, dimy:%d, numframes:%d, numparticles:%d", IszX, IszY, Nfr, Nparticles);
    resultDB.AddResult("particlefilter_float_kernel_time", atts, "sec", kernelTime);
    resultDB.AddResult("particlefilter_float_transfer_time", atts, "sec", transferTime);
    resultDB.AddResult("particlefilter_float_total_time", atts, "sec", kernelTime+transferTime);
    resultDB.AddResult("particlefilter_float_parity", atts, "N", transferTime / kernelTime);
    resultDB.AddOverall("Time", "sec", kernelTime+transferTime);

    //CUDA freeing of memory
    cudaFree(weights_GPU);
    cudaFree(arrayY_GPU);
    cudaFree(arrayX_GPU);

    //free regular memory
    free(likelihood);
    free(arrayX);
    free(arrayY);
    free(xj);
    free(yj);
    free(CDF);
    free(ind);
    free(u);
}

/**
 * The implementation of the particle filter using OpenMP for many frames
 * @see http://openmp.org/wp/
 * @note This function is designed to work with a video of several frames. In addition, it references a provided MATLAB function which takes the video, the objxy matrix and the x and y arrays as arguments and returns the likelihoods
 * @param I The video to be run
 * @param IszX The x dimension of the video
 * @param IszY The y dimension of the video
 * @param Nfr The number of frames
 * @param seed The seed array used for random number generation
 * @param Nparticles The number of particles to be used
 */
void particleFilterGraph(unsigned char * I, int IszX, int IszY, int Nfr, int * seed, int Nparticles, ResultDatabase &resultDB) {

    float kernelTime = 0.0f;
    float transferTime = 0.0f;
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    float elapsedTime;

    int max_size = IszX * IszY*Nfr;
    //original particle centroid
    double xe = roundDouble(IszY / 2.0);
    double ye = roundDouble(IszX / 2.0);

    //expected object locations, compared to center
    int radius = 5;
    int diameter = radius * 2 - 1;
    int * disk = (int*) malloc(diameter * diameter * sizeof (int));
    strelDisk(disk, radius);
    int countOnes = 0;
    int x, y;
    for (x = 0; x < diameter; x++) {
        for (y = 0; y < diameter; y++) {
            if (disk[x * diameter + y] == 1)
                countOnes++;
        }
    }
    int * objxy = (int *) malloc(countOnes * 2 * sizeof (int));
    getneighbors(disk, countOnes, objxy, radius);
    //initial weights are all equal (1/Nparticles)
    double * weights = (double *) malloc(sizeof (double) *Nparticles);
    for (x = 0; x < Nparticles; x++) {
        weights[x] = 1 / ((double) (Nparticles));
    }

    //initial likelihood to 0.0
    double * likelihood = (double *) malloc(sizeof (double) *Nparticles);
    double * arrayX = (double *) malloc(sizeof (double) *Nparticles);
    double * arrayY = (double *) malloc(sizeof (double) *Nparticles);
    double * xj = (double *) malloc(sizeof (double) *Nparticles);
    double * yj = (double *) malloc(sizeof (double) *Nparticles);
    double * CDF = (double *) malloc(sizeof (double) *Nparticles);

    //GPU copies of arrays
    double * arrayX_GPU;
    double * arrayY_GPU;
    double * xj_GPU;
    double * yj_GPU;
    double * CDF_GPU;
    double * likelihood_GPU;
    unsigned char * I_GPU;
    double * weights_GPU;
    int * objxy_GPU;

    int * ind = (int*) malloc(sizeof (int) *countOnes * Nparticles);
    int * ind_GPU;
    double * u = (double *) malloc(sizeof (double) *Nparticles);
    double * u_GPU;
    int * seed_GPU;
    double* partial_sums;

    //CUDA memory allocation
    CUDA_SAFE_CALL(cudaMalloc((void **) &arrayX_GPU, sizeof (double) *Nparticles));
    CUDA_SAFE_CALL(cudaMalloc((void **) &arrayY_GPU, sizeof (double) *Nparticles));
    CUDA_SAFE_CALL(cudaMalloc((void **) &xj_GPU, sizeof (double) *Nparticles));
    CUDA_SAFE_CALL(cudaMalloc((void **) &yj_GPU, sizeof (double) *Nparticles));
    CUDA_SAFE_CALL(cudaMalloc((void **) &CDF_GPU, sizeof (double) *Nparticles));
    CUDA_SAFE_CALL(cudaMalloc((void **) &u_GPU, sizeof (double) *Nparticles));
    CUDA_SAFE_CALL(cudaMalloc((void **) &likelihood_GPU, sizeof (double) *Nparticles));
    //set likelihood to zero
    CUDA_SAFE_CALL(cudaMemset((void *) likelihood_GPU, 0, sizeof (double) *Nparticles));
    CUDA_SAFE_CALL(cudaMalloc((void **) &weights_GPU, sizeof (double) *Nparticles));
    CUDA_SAFE_CALL(cudaMalloc((void **) &I_GPU, sizeof (unsigned char) *IszX * IszY * Nfr));
    CUDA_SAFE_CALL(cudaMalloc((void **) &objxy_GPU, sizeof (int) *2 * countOnes));
    CUDA_SAFE_CALL(cudaMalloc((void **) &ind_GPU, sizeof (int) *countOnes * Nparticles));
    CUDA_SAFE_CALL(cudaMalloc((void **) &seed_GPU, sizeof (int) *Nparticles));
    CUDA_SAFE_CALL(cudaMalloc((void **) &partial_sums, sizeof (double) *Nparticles));


    //Donnie - this loop is different because in this kernel, arrayX and arrayY
    //  are set equal to xj before every iteration, so effectively, arrayX and 
    //  arrayY will be set to xe and ye before the first iteration.
    for (x = 0; x < Nparticles; x++) {

        xj[x] = xe;
        yj[x] = ye;

    }

    int k;
    //start send
    cudaEventRecord(start, 0);

    CUDA_SAFE_CALL(cudaMemcpy(I_GPU, I, sizeof (unsigned char) *IszX * IszY*Nfr, cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(objxy_GPU, objxy, sizeof (int) *2 * countOnes, cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(weights_GPU, weights, sizeof (double) *Nparticles, cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(xj_GPU, xj, sizeof (double) *Nparticles, cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(yj_GPU, yj, sizeof (double) *Nparticles, cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(seed_GPU, seed, sizeof (int) *Nparticles, cudaMemcpyHostToDevice));
    int num_blocks = ceil((double) Nparticles / (double) threads_per_block);
    
    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&elapsedTime, start, stop);
    transferTime += elapsedTime * 1.e-3;

    // Init graph metadata
    cudaStream_t streamForGraph;
    cudaGraph_t graph;
    cudaGraphNode_t likelihoodKernelNode, sumKernelNode, normalizeWeightsKernelNode, findIndexKernelNode;
    
    checkCudaErrors(cudaGraphCreate(&graph, 0));
    checkCudaErrors(cudaStreamCreate(&streamForGraph));

    // Set up first kernel node
    cudaKernelNodeParams likelihoodKernelNodeParams = {0};
    void *likelihoodKernelArgs[19] = {(void *)&arrayX_GPU, (void *)&arrayY_GPU,
                                      (void *)&xj_GPU, (void *)&yj_GPU,
                                      (void *)&CDF_GPU, (void *)&ind_GPU,
                                      (void *)&objxy_GPU, (void *)&likelihood_GPU,
                                      (void *)&I_GPU, (void *)&u_GPU,
                                      (void *)&weights_GPU, &Nparticles,
                                      &countOnes, &max_size, &k, &IszY,
                                      &Nfr, (void *)&seed_GPU, (void *)&partial_sums};
    likelihoodKernelNodeParams.func = (void *)likelihood_kernel;
    likelihoodKernelNodeParams.gridDim = dim3(num_blocks, 1, 1);
    likelihoodKernelNodeParams.blockDim = dim3(threads_per_block, 1, 1);
    likelihoodKernelNodeParams.sharedMemBytes = 0;
    likelihoodKernelNodeParams.kernelParams = (void **)likelihoodKernelArgs;
    likelihoodKernelNodeParams.extra = NULL;

    checkCudaErrors(cudaGraphAddKernelNode(&likelihoodKernelNode, graph, NULL, 0, &likelihoodKernelNodeParams));

    // Set up the second kernel node
    cudaKernelNodeParams sumKernelNodeParams = {0};
    void *sumKernelArgs[2] = {(void *)&partial_sums, &Nparticles};
    sumKernelNodeParams.func = (void *)sum_kernel;
    sumKernelNodeParams.gridDim = dim3(num_blocks, 1, 1);
    sumKernelNodeParams.blockDim = dim3(threads_per_block, 1, 1);
    sumKernelNodeParams.sharedMemBytes = 0;
    sumKernelNodeParams.kernelParams = (void **)sumKernelArgs;
    sumKernelNodeParams.extra = NULL;

    checkCudaErrors(cudaGraphAddKernelNode(&sumKernelNode, graph, NULL, 0, &sumKernelNodeParams));

    // set up the third kernel node
    cudaKernelNodeParams normalizeWeightsKernelNodeParams = {0};
    void *normalizeWeightsKernelArgs[6] = {(void *)&weights_GPU, &Nparticles,
                                           (void *)&partial_sums, (void *)&CDF_GPU,
                                           (void *)&u_GPU, (void *)&seed_GPU};
    normalizeWeightsKernelNodeParams.func = (void *)normalize_weights_kernel;
    normalizeWeightsKernelNodeParams.gridDim = dim3(num_blocks, 1, 1);
    normalizeWeightsKernelNodeParams.blockDim = dim3(threads_per_block, 1, 1);
    normalizeWeightsKernelNodeParams.sharedMemBytes = 0;
    normalizeWeightsKernelNodeParams.kernelParams = (void **)normalizeWeightsKernelArgs;
    normalizeWeightsKernelNodeParams.extra = NULL;

    checkCudaErrors(cudaGraphAddKernelNode(&normalizeWeightsKernelNode, graph, NULL, 0, &normalizeWeightsKernelNodeParams));

    // set up the fourth kernel node
    cudaKernelNodeParams findIndexKernelNodeParams = {0};
    void *findIndexKernelArgs[8] = {(void *)&arrayX_GPU, (void *)&arrayY_GPU, (void *)&CDF_GPU,
                                    (void *)&u_GPU, (void *)&xj_GPU,
                                    (void *)&yj_GPU, (void *)&weights_GPU,
                                    &Nparticles};
    findIndexKernelNodeParams.func = (void *)find_index_kernel;
    findIndexKernelNodeParams.gridDim = dim3(num_blocks, 1, 1);
    findIndexKernelNodeParams.blockDim = dim3(threads_per_block, 1, 1);
    findIndexKernelNodeParams.sharedMemBytes = 0;
    findIndexKernelNodeParams.kernelParams = (void **)findIndexKernelArgs;
    findIndexKernelNodeParams.extra = NULL;

    checkCudaErrors(cudaGraphAddKernelNode(&findIndexKernelNode, graph, NULL, 0, &findIndexKernelNodeParams));

    // Add dependencies between each kernels
    checkCudaErrors(cudaGraphAddDependencies(graph, &likelihoodKernelNode, &sumKernelNode, 1));
    checkCudaErrors(cudaGraphAddDependencies(graph, &sumKernelNode, &normalizeWeightsKernelNode, 1));
    checkCudaErrors(cudaGraphAddDependencies(graph, &normalizeWeightsKernelNode, &findIndexKernelNode, 1));

    // init the graph
    cudaGraphExec_t graphExec;
    checkCudaErrors(cudaGraphInstantiate(&graphExec, graph, NULL, NULL, 0));


    double wall1 = get_wall_time();
    for (k = 1; k < Nfr; k++) {
       
        checkCudaErrors(cudaEventRecord(start, 0));
        checkCudaErrors(cudaGraphLaunch(graphExec, streamForGraph));
        checkCudaErrors(cudaEventRecord(stop, 0));
        checkCudaErrors(cudaEventSynchronize(stop));
        checkCudaErrors(cudaEventElapsedTime(&elapsedTime, start, stop));
        kernelTime += elapsedTime * 1.e-3;

    }//end loop

    //block till kernels are finished
    checkCudaErrors(cudaStreamSynchronize(streamForGraph));
    double wall2 = get_wall_time();

    checkCudaErrors(cudaGraphExecDestroy(graphExec));
    checkCudaErrors(cudaGraphDestroy(graph));
    checkCudaErrors(cudaStreamDestroy(streamForGraph));

    cudaFree(xj_GPU);
    cudaFree(yj_GPU);
    cudaFree(CDF_GPU);
    cudaFree(u_GPU);
    cudaFree(likelihood_GPU);
    cudaFree(I_GPU);
    cudaFree(objxy_GPU);
    cudaFree(ind_GPU);
    cudaFree(seed_GPU);
    cudaFree(partial_sums);

    cudaEventRecord(start, 0);
    CUDA_SAFE_CALL(cudaMemcpy(arrayX, arrayX_GPU, sizeof (double) *Nparticles, cudaMemcpyDeviceToHost));
    CUDA_SAFE_CALL(cudaMemcpy(arrayY, arrayY_GPU, sizeof (double) *Nparticles, cudaMemcpyDeviceToHost));
    CUDA_SAFE_CALL(cudaMemcpy(weights, weights_GPU, sizeof (double) *Nparticles, cudaMemcpyDeviceToHost));
    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&elapsedTime, start, stop);
    transferTime += elapsedTime * 1.e-3;

    xe = 0;
    ye = 0;
    // estimate the object location by expected values
    for (x = 0; x < Nparticles; x++) {
        xe += arrayX[x] * weights[x];
        ye += arrayY[x] * weights[x];
    }
    if(verbose && !quiet) {
        printf("XE: %lf\n", xe);
        printf("YE: %lf\n", ye);
        double distance = sqrt(pow((double) (xe - (int) roundDouble(IszY / 2.0)), 2) + pow((double) (ye - (int) roundDouble(IszX / 2.0)), 2));
        printf("%lf\n", distance);
    }
    
    char atts[1024];
    sprintf(atts, "dimx:%d, dimy:%d, numframes:%d, numparticles:%d", IszX, IszY, Nfr, Nparticles);
    resultDB.AddResult("particlefilter_float_kernel_time", atts, "sec", kernelTime);
    resultDB.AddResult("particlefilter_float_transfer_time", atts, "sec", transferTime);
    resultDB.AddResult("particlefilter_float_total_time", atts, "sec", kernelTime+transferTime);
    resultDB.AddResult("particlefilter_float_parity", atts, "N", transferTime / kernelTime);
    resultDB.AddOverall("Time", "sec", kernelTime+transferTime);

    //CUDA freeing of memory
    cudaFree(weights_GPU);
    cudaFree(arrayY_GPU);
    cudaFree(arrayX_GPU);

    //free regular memory
    free(likelihood);
    free(arrayX);
    free(arrayY);
    free(xj);
    free(yj);
    free(CDF);
    free(ind);
    free(u);
}

void addBenchmarkSpecOptions(OptionParser &op) {
  op.addOption("dimx", OPT_INT, "0", "grid x dimension", 'x');
  op.addOption("dimy", OPT_INT, "0", "grid y dimension", 'y');
  op.addOption("framecount", OPT_INT, "0", "number of frames to track across", 'f');
  op.addOption("np", OPT_INT, "0", "number of particles to use");
}

void particlefilter_float(ResultDatabase &resultDB, int args[], bool useGraph);

void RunBenchmark(ResultDatabase &resultDB, OptionParser &op) {
    printf("Running ParticleFilter (float)\n");
    int args[4];
    args[0] = op.getOptionInt("dimx");
    args[1] = op.getOptionInt("dimy");
    args[2] = op.getOptionInt("framecount");
    args[3] = op.getOptionInt("np");
    bool preset = false;
    verbose = op.getOptionBool("verbose");
    quiet = op.getOptionBool("quiet");
    bool useGraph = op.getOptionBool("graph");

    for(int i = 0; i < 4; i++) {
        if(args[i] <= 0) {
            preset = true;
        }
    }
    if(preset) {
        int probSizes[4][4] = {{10, 10, 2, 100},
                               {40, 40, 5, 500},
                               {200, 200, 8, 500000},
                               {500, 500, 15, 1000000}};
        int size = op.getOptionInt("size") - 1;
        for(int i = 0; i < 4; i++) {
            args[i] = probSizes[size][i];
        }
    }

    if(!quiet) {
        printf("Using dimx=%d, dimy=%d, framecount=%d, numparticles=%d\n",
                args[0], args[1], args[2], args[3]);
    }

    int passes = op.getOptionInt("passes");
    for(int i = 0; i < passes; i++) {
        if(!quiet) {
            printf("Pass %d: ", i);
        }
        particlefilter_float(resultDB, args, useGraph);
        if(!quiet) {
            printf("Done.\n");
        }
    }
}

void particlefilter_float(ResultDatabase &resultDB, int args[], bool useGraph) {

    int IszX, IszY, Nfr, Nparticles;
	IszX = args[0];
	IszY = args[1];
    Nfr = args[2];
    Nparticles = args[3];

    //establish seed
    int * seed = (int *) malloc(sizeof (int) *Nparticles);
    int i;
    for (i = 0; i < Nparticles; i++)
        seed[i] = time(0) * i;
    //malloc matrix
    unsigned char * I = (unsigned char *) malloc(sizeof (unsigned char) *IszX * IszY * Nfr);
    //call video sequence
    videoSequence(I, IszX, IszY, Nfr, seed);
    //call particle filter
    if (useGraph) particleFilterGraph(I, IszX, IszY, Nfr, seed, Nparticles, resultDB);
    else particleFilter(I, IszX, IszY, Nfr, seed, Nparticles, resultDB);

    free(seed);
    free(I);
}
